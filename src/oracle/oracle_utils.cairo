// *************************************************************************
//                                  IMPORTS
// *************************************************************************
// Core lib imports.
use starknet::ContractAddress;
use result::ResultTrait;
use traits::Default;

// Local imports.
use satoru::data::data_store::{IDataStoreDispatcher, IDataStoreDispatcherTrait};
use satoru::event::event_emitter::{IEventEmitterDispatcher, IEventEmitterDispatcherTrait};
use satoru::bank::bank::{IBankDispatcher, IBankDispatcherTrait};
use satoru::market::market::{Market};
use satoru::oracle::oracle::{SetPricesCache, SetPricesInnerCache};
use satoru::price::price::{Price};
use satoru::utils::store_arrays::{
    StoreContractAddressArray, StorePriceArray, StoreU128Array, StoreFelt252Array
};
use satoru::utils::arrays::{are_lte, get_uncompacted_value, get_uncompacted_value_u64};
use satoru::utils::bits::{BITMASK_8, BITMASK_16, BITMASK_32, BITMASK_64};
use satoru::oracle::error::{OracleError};


/// SetPricesParams struct for values required in Oracle.set_prices.
/// # Arguments
/// * `signer_info` - compacted indexes of signers, the index is used to retrieve
/// the signer address from the OracleStore.
/// * `tokens` - list of tokens to set prices for.
/// * `compacted_oracle_block_numbers` - compacted oracle block numbers.
/// * `compacted_oracle_timestamps` - compacted oracle timestamps.
/// * `compacted_decimals` - compacted decimals for prices.
/// * `compacted_min_prices` - compacted min prices.
/// * `compacted_min_prices_indexes` - compacted min price indexes.
/// * `compacted_max_prices` - compacted max prices.
/// * `compacted_max_prices_indexes` - compacted max price indexes.
/// * `signatures` - signatures of the oracle signers.
/// * `price_feed_tokens` - tokens to set prices for based on an external price feed value.
#[derive(Default, Drop, Clone, Serde)]
struct SetPricesParams {
    signer_info: u128,
    tokens: Array<ContractAddress>,
    compacted_min_oracle_block_numbers: Array<u64>,
    compacted_max_oracle_block_numbers: Array<u64>,
    compacted_oracle_timestamps: Array<u64>,
    compacted_decimals: Array<u128>,
    compacted_min_prices: Array<u128>,
    compacted_min_prices_indexes: Array<u128>,
    compacted_max_prices: Array<u128>,
    compacted_max_prices_indexes: Array<u128>,
    signatures: Array<felt252>,
    price_feed_tokens: Array<ContractAddress>,
}

#[derive(Drop, Clone, starknet::Store, Serde)]
struct SimulatePricesParams {
    primary_tokens: Array<ContractAddress>,
    primary_prices: Array<Price>,
}


/// # Arguments
/// * `min_oracle_block_number` - The min block number used for the signed message hash.
/// * `max_oracle_block_number` - The max block number used for the signed message hash.
/// * `oracle_timestamp` - The timestamp used for the signed message hash.
/// * `block_hash` - The block hash used for the signed message hash.
/// * `token` - The token used for the signed message hash.
/// * `token_oracle_type` - The type of token used for the signed message hash.
/// * `precision` - The precision used for the signed message hash.
/// * `min_price` - The min price used for the signed message hash.
/// * `max_price` - The max price used for the signed message hash.
#[derive(Copy, Drop, starknet::Store, Serde)]
struct ReportInfo {
    min_oracle_block_number: u64,
    max_oracle_block_number: u64,
    oracle_timestamp: u64,
    block_hash: felt252,
    token: ContractAddress,
    token_oracle_type: felt252,
    precision: u128,
    min_price: u128,
    max_price: u128,
}

// compacted prices have a length of 32 bits
const COMPACTED_PRICE_BIT_LENGTH: usize = 32;
fn COMPACTED_PRICE_BITMASK() -> u128 {
    BITMASK_32
}

// compacted precisions have a length of 8 bits
const COMPACTED_PRECISION_BIT_LENGTH: usize = 8;
fn COMPACTED_PRECISION_BITMASK() -> u128 {
    BITMASK_8
}

// compacted block numbers have a length of 64 bits
const COMPACTED_BLOCK_NUMBER_BIT_LENGTH: usize = 64;
fn COMPACTED_BLOCK_NUMBER_BITMASK() -> u64 {
    BITMASK_64
}

// compacted timestamps have a length of 64 bits
const COMPACTED_TIMESTAMP_BIT_LENGTH: usize = 64;
fn COMPACTED_TIMESTAMP_BITMASK() -> u64 {
    BITMASK_64
}

// compacted price indexes have a length of 8 bits
const COMPACTED_PRICE_INDEX_BIT_LENGTH: usize = 8;
fn COMPACTED_PRICE_INDEX_BITMASK() -> u128 {
    BITMASK_8
}

/// Validates wether a block number is in range.
/// # Arguments
/// * `min_oracle_block_numbers` - The oracles block number that should be less than block_number.
/// * `max_oracle_block_numbers` - The oracles block number that should be higher than block_number.
/// * `block_number` - The block number to compare to.
fn validate_block_number_within_range(
    min_oracle_block_numbers: Array<u128>, max_oracle_block_numbers: Array<u128>, block_number: u128
) {
    if (!is_block_number_within_range(
        min_oracle_block_numbers, max_oracle_block_numbers, block_number
    )) {
        OracleError::BLOCK_NUMBER_NOT_WITHIN_RANGE()
    }
}

/// Validates wether a block number is in range.
/// # Arguments
/// * `min_oracle_block_numbers` - The oracles block number that should be less than block_number.
/// * `max_oracle_block_numbers` - The oracles block number that should be higher than block_number.
/// * `block_number` - The block number to compare to.
/// # Returns
/// True if block_number is in range, false else.
fn is_block_number_within_range(
    min_oracle_block_numbers: Array<u128>, max_oracle_block_numbers: Array<u128>, block_number: u128
) -> bool {
    if (!are_lte(min_oracle_block_numbers.span(), block_number)) {
        return false;
    }

    if (!are_lte(max_oracle_block_numbers.span(), block_number)) {
        return false;
    }

    true
}

/// Get the uncompacted price at the specified index.
/// # Arguments
/// * `compacted_prices` - The compacted prices.
/// * `index` - The index to get the decimal at.
/// # Returns
/// The price at the specified index.
fn get_uncompacted_price(compacted_prices: Span<u128>, index: usize) -> u128 {
    let price = get_uncompacted_value(
        compacted_prices,
        index,
        COMPACTED_PRICE_BIT_LENGTH,
        COMPACTED_PRICE_BITMASK(),
        "get_uncompacted_price"
    );

    if (price == 0) {
        OracleError::EMPTY_COMPACTED_PRICE(index)
    }

    price
}

/// Get the uncompacted decimal at the specified index.
/// # Arguments
/// * `compacted_decimals` - The compacted decimals.
/// * `index` - The index to get the decimal at.
/// # Returns
/// The decimal at the specified index.
fn get_uncompacted_decimal(compacted_decimals: Span<u128>, index: usize) -> u128 {
    let decimal = get_uncompacted_value(
        compacted_decimals,
        index,
        COMPACTED_PRECISION_BIT_LENGTH,
        COMPACTED_PRECISION_BITMASK(),
        "get_uncompacted_decimal"
    );

    decimal
}

/// Get the uncompacted price index at the specified index.
/// # Arguments
/// * `compacted_price_indexes` - The compacted indexes.
/// * `index` - The index to get the price index at.
/// # Returns
/// The uncompacted price index at the specified index.
fn get_uncompacted_price_index(compacted_price_indexes: Span<u128>, index: usize) -> u128 {
    let price_index = get_uncompacted_value(
        compacted_price_indexes,
        index,
        COMPACTED_PRICE_INDEX_BIT_LENGTH,
        COMPACTED_PRICE_INDEX_BITMASK(),
        "get_uncompacted_price_index"
    );

    price_index
}

/// Get the uncompacted oracle block numbers.
/// # Arguments
/// * `compacted_oracle_block_numbers` - The compacted oracle block numbers.
/// * `length` - The length of the uncompacted oracle block numbers.
/// # Returns
/// The uncompacted oracle block numbers.
fn get_uncompacted_oracle_block_numbers(
    compacted_oracle_block_numbers: Span<u64>, length: usize
) -> Array<u64> {
    let mut block_numbers = ArrayTrait::new();

    let mut i = 0;
    loop {
        if (i == length) {
            break;
        }

        block_numbers
            .append(get_uncompacted_oracle_block_number(compacted_oracle_block_numbers, i));

        i += 1;
    };

    block_numbers
}

/// Get the uncompacted oracle block number.
/// # Arguments
/// * `compacted_oracle_block_numbers` - The compacted oracle block numbers.
/// * `index` - The index to get the uncompacted oracle block number at.
/// # Returns
/// The uncompacted oracle block number.
fn get_uncompacted_oracle_block_number(
    compacted_oracle_block_numbers: Span<u64>, index: usize
) -> u64 {
    let block_number = get_uncompacted_value_u64(
        compacted_oracle_block_numbers,
        index,
        COMPACTED_BLOCK_NUMBER_BIT_LENGTH,
        COMPACTED_BLOCK_NUMBER_BITMASK(),
        "get_uncompacted_oracle_block_number"
    );

    block_number
}

/// Get the uncompacted oracle timestamp.
/// # Arguments
/// * `compacted_oracle_timestamps` - The compacted oracle timestamps.
/// * `index` - The index to get the uncompacted oracle timestamp at.
/// # Returns
/// The uncompacted oracle timestamp.
fn get_uncompacted_oracle_timestamp(compacted_oracle_timestamps: Span<u64>, index: usize) -> u64 {
    let timestamp = get_uncompacted_value_u64(
        compacted_oracle_timestamps,
        index,
        COMPACTED_TIMESTAMP_BIT_LENGTH,
        COMPACTED_TIMESTAMP_BITMASK(),
        "get_uncompacted_oracle_timestamp"
    );

    if (timestamp == 0) {
        OracleError::EMPTY_COMPACTED_TIMESTAMP(index);
    }

    timestamp
}

/// Validate the signer of a price.
/// Before calling this function, the expected_signer should be validated to
/// ensure that it is not the zero address.
/// # Arguments
/// * `min_oracle_block_number` - The min block number used for the signed message hash.
/// * `max_oracle_block_number` - The max block number used for the signed message hash.
/// * `oracle_timestamp` - The timestamp used for the signed message hash.
/// * `block_hash` - The block hash used for the signed message hash.
/// * `token` - The token used for the signed message hash.
/// * `token_oracle_type` - The type of token used for the signed message hash.
/// * `precision` - The precision used for the signed message hash.
/// * `min_price` - The min price used for the signed message hash.
/// * `max_price` - The max price used for the signed message hash.
/// * `signature` - The signer's signature.
/// * `expected_signer` - The address of the expected signer.
fn validate_signer(
    salt: felt252, info: ReportInfo, signature: felt252, expected_signer: @ContractAddress
) { // TODO
}

/// Revert with OracleBlockNumberNotWithinRange error.
/// # Arguments
/// * `max_oracle_block_number` - The max block number used for the signed message hash.
/// * `block` - The current block number.
fn revert_oracle_block_number_not_within_range(
    min_oracle_block_numbers: Array<u128>, max_oracle_block_numbers: Array<u128>, block_number: u64
) { // TODO
}

/// Check wether `error` is an OracleError.
/// # Arguments
/// * `error` - The error to check.
/// # Returns
/// Wether it's the right error.
fn is_oracle_error(error_selector: felt252) -> bool {
    // TODO
    true
}

/// Check wether `error` is an EmptyPriceError.
/// # Arguments
/// * `error` - The error to check.
/// # Returns
/// Wether it's the right error.
fn is_empty_price_error(error_selector: felt252) -> bool {
    // TODO
    true
}

/// Check wether `error` is an OracleBlockNumberError.
/// # Arguments
/// * `error` - The error to check.
/// # Returns
/// Wether it's the right error.
fn is_oracle_block_number_error(error_selector: felt252) -> bool {
    // TODO
    true
}

impl DefaultReportInfo of Default<ReportInfo> {
    fn default() -> ReportInfo {
        ReportInfo {
            min_oracle_block_number: 0,
            max_oracle_block_number: 0,
            oracle_timestamp: 0,
            block_hash: 0,
            token: Zeroable::zero(),
            token_oracle_type: 0,
            precision: 0,
            min_price: 0,
            max_price: 0,
        }
    }
}

