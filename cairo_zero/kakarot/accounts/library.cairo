%lang starknet

from openzeppelin.access.ownable.library import Ownable, Ownable_owner
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.cairo_builtins import HashBuiltin, BitwiseBuiltin
from starkware.cairo.common.math import split_int
from starkware.cairo.common.memcpy import memcpy
from starkware.cairo.common.uint256 import Uint256, uint256_lt
from starkware.cairo.common.math_cmp import is_nn, is_le_felt
from starkware.starknet.common.syscalls import (
    StorageRead,
    StorageWrite,
    STORAGE_READ_SELECTOR,
    STORAGE_WRITE_SELECTOR,
    storage_read,
    storage_write,
    StorageReadRequest,
    CallContract,
    get_contract_address,
    get_caller_address,
)
from starkware.cairo.common.memset import memset

from kakarot.interfaces.interfaces import IERC20, IKakarot, ICairo1Helpers
from kakarot.accounts.model import CallArray
from kakarot.errors import Errors
from kakarot.constants import Constants
from utils.eth_transaction import EthTransaction
from utils.bytes import bytes_to_bytes8_little_endian
from utils.signature import Signature
from utils.utils import Helpers
from utils.maths import unsigned_div_rem

// @dev: should always be zero for EOAs
@storage_var
func Account_bytecode_len() -> (res: felt) {
}

@storage_var
func Account_storage(key: Uint256) -> (value: Uint256) {
}

@storage_var
func Account_is_initialized() -> (res: felt) {
}

@storage_var
func Account_nonce() -> (nonce: felt) {
}

@storage_var
func Account_evm_address() -> (evm_address: felt) {
}

@storage_var
func Account_valid_jumpdests() -> (is_valid: felt) {
}

@storage_var
func Account_authorized_message_hashes(hash: Uint256) -> (res: felt) {
}

@storage_var
func Account_code_hash() -> (code_hash: Uint256) {
}

@event
func transaction_executed(response_len: felt, response: felt*, success: felt, gas_used: felt) {
}

const BYTES_PER_FELT = 31;

const SECP256K1N_DIV_2_LOW = 0x5d576e7357a4501ddfe92f46681b20a0;
const SECP256K1N_DIV_2_HIGH = 0x7fffffffffffffffffffffffffffffff;

// @title Account main library file.
// @notice This file contains the EVM account representation logic.
// @dev: Both EOAs and Contract Accounts are represented by this contract. Owner is expected to be Kakarot.
namespace AccountContract {
    // @notice This function is used to initialize the smart contract account.
    // @dev The `evm_address` and `kakarot_address` were set during the uninitialized_account creation.
    // Reading them from state ensures that they always match the ones the account was created for.
    // @param evm_address The EVM address of the account.
    func initialize{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(evm_address: felt) {
        alloc_locals;
        let (is_initialized) = Account_is_initialized.read();
        with_attr error_message("Account already initialized") {
            assert is_initialized = 0;
        }
        Account_is_initialized.write(1);
        Account_evm_address.write(evm_address);

        // Give infinite ETH transfer allowance to Kakarot
        let (kakarot_address) = Ownable_owner.read();
        let (native_token_address) = IKakarot.get_native_token(kakarot_address);
        let infinite = Uint256(Constants.UINT128_MAX, Constants.UINT128_MAX);
        IERC20.approve(native_token_address, kakarot_address, infinite);

        // Register the account in the Kakarot mapping
        IKakarot.register_account(kakarot_address, evm_address);
        return ();
    }

    // @notice This function returns the EVM address of the account.
    // @return address The EVM address of the account.
    func get_evm_address{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
        address: felt
    ) {
        let (address) = Account_evm_address.read();
        return (address=address);
    }

    // @notice This function checks if the account was initialized.
    // @return is_initialized 1 if the account has been initialized, 0 otherwise.
    func is_initialized{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }() -> (is_initialized: felt) {
        let is_initialized: felt = Account_is_initialized.read();
        return (is_initialized=is_initialized);
    }

    // @notice Validate an Ethereum transaction and execute it.
    // @dev This function validates the transaction by checking its signature,
    // chain_id, nonce and gas. It then sends it to Kakarot.
    // @param tx_data_len The length of tx data.
    // @param tx_data The tx data.
    // @param signature_len The length of tx signature.
    // @param signature The tx signature.
    // @param chain_id The expected chain id of the tx.
    // @return response_len The length of the response array.
    // @return response The response from the Kakarot contract.
    func execute_from_outside{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        bitwise_ptr: BitwiseBuiltin*,
        range_check_ptr,
    }(tx_data_len: felt, tx_data: felt*, signature_len: felt, signature: felt*, chain_id: felt) -> (
        response_len: felt, response: felt*
    ) {
        alloc_locals;

        with_attr error_message("Incorrect signature length") {
            assert signature_len = 5;
        }

        with_attr error_message("Signatures values not in range") {
            assert [range_check_ptr] = signature[0];
            assert [range_check_ptr + 1] = signature[1];
            assert [range_check_ptr + 2] = signature[2];
            assert [range_check_ptr + 3] = signature[3];
            assert [range_check_ptr + 4] = signature[4];
            let range_check_ptr = range_check_ptr + 5;
        }

        let r = Uint256(signature[0], signature[1]);
        let s = Uint256(signature[2], signature[3]);
        let v = signature[4];

        let tx_type = EthTransaction.get_tx_type(tx_data_len, tx_data);
        local y_parity: felt;
        local pre_eip155_tx: felt;
        if (tx_type == 0) {
            let is_eip155_tx = is_nn(28 - v);
            assert pre_eip155_tx = is_eip155_tx;
            if (is_eip155_tx != FALSE) {
                assert y_parity = v - 27;
            } else {
                assert y_parity = (v - 2 * chain_id - 35);
            }
            tempvar range_check_ptr = range_check_ptr;
        } else {
            assert pre_eip155_tx = FALSE;
            assert y_parity = v;
            tempvar range_check_ptr = range_check_ptr;
        }
        let range_check_ptr = [ap - 1];

        // Signature validation
        // `verify_eth_signature_uint256` verifies that r and s are in the range [1, N[
        // TX validation imposes s to be the range [1, N//2], see EIP-2
        let (is_invalid_upper_s) = uint256_lt(
            Uint256(SECP256K1N_DIV_2_LOW, SECP256K1N_DIV_2_HIGH), s
        );
        with_attr error_message("Invalid s value") {
            assert is_invalid_upper_s = FALSE;
        }

        let (local words: felt*) = alloc();
        let (words_len, last_word, last_word_num_bytes) = bytes_to_bytes8_little_endian(
            words, tx_data_len, tx_data
        );
        let (kakarot_address) = Ownable_owner.read();
        let (helpers_class) = IKakarot.get_cairo1_helpers_class_hash(kakarot_address);
        let (msg_hash) = ICairo1Helpers.library_call_keccak(
            class_hash=helpers_class,
            words_len=words_len,
            words=words,
            last_input_word=last_word,
            last_input_num_bytes=last_word_num_bytes,
        );
        let (address) = Account_evm_address.read();
        Signature.verify_eth_signature_uint256(
            msg_hash=msg_hash,
            r=r,
            s=s,
            y_parity=y_parity,
            eth_address=address,
            helpers_class=helpers_class,
        );

        // Whitelisting pre-eip155
        let (is_authorized) = Account_authorized_message_hashes.read(msg_hash);
        if (pre_eip155_tx != FALSE) {
            with_attr error_message("Unauthorized pre-eip155 transaction") {
                assert is_authorized = TRUE;
            }
        }

        // Send tx to Kakarot
        let (return_data_len, return_data, success, gas_used) = IKakarot.eth_send_raw_unsigned_tx(
            contract_address=kakarot_address, tx_data_len=tx_data_len, tx_data=tx_data
        );

        // See Argent account
        // https://github.com/argentlabs/argent-contracts-starknet/blob/c6d3ee5e05f0f4b8a5c707b4094446c3bc822427/contracts/account/ArgentAccount.cairo#L132
        // See 300 max data_len for events
        // https://github.com/starkware-libs/blockifier/blob/9bfb3d4c8bf1b68a0c744d1249b32747c75a4d87/crates/blockifier/resources/versioned_constants.json
        // The whole data_len should be less than 300, so it's the return_data should be less than 297 (+3 for return_data_len, success, gas_used)
        tempvar capped_return_data_len = is_nn(297 - return_data_len) * (return_data_len - 297) +
            297;
        transaction_executed.emit(
            response_len=capped_return_data_len,
            response=return_data,
            success=success,
            gas_used=gas_used,
        );

        // Return the unmodified return_data_len.
        return (response_len=return_data_len, response=return_data);
    }

    // @notice Store the bytecode of the contract.
    // @param bytecode_len The length of the bytecode.
    // @param bytecode The bytecode of the contract.
    func write_bytecode{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(bytecode_len: felt, bytecode: felt*) {
        alloc_locals;
        // Recursively store the bytecode.
        Account_bytecode_len.write(bytecode_len);
        Internals.write_bytecode(bytecode_len=bytecode_len, bytecode=bytecode);
        return ();
    }

    // @notice This function is used to get the bytecode_len of the smart contract.
    // @return res The length of the bytecode.
    func bytecode_len{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
        res: felt
    ) {
        return Account_bytecode_len.read();
    }

    // @notice This function is used to get the bytecode of the smart contract.
    // @return bytecode_len The length of the bytecode.
    // @return bytecode The bytecode of the smart contract.
    func bytecode{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }() -> (bytecode_len: felt, bytecode: felt*) {
        alloc_locals;
        let (bytecode_len) = Account_bytecode_len.read();
        let (bytecode_) = Internals.load_bytecode(bytecode_len);
        return (bytecode_len, bytecode_);
    }

    // @notice This function is used to read the storage at a key.
    // @param storage_addr The storage address.
    // @return value The stored value.
    func storage{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(storage_addr: felt) -> (value: Uint256) {
        let (low) = storage_read(address=storage_addr + 0);
        let (high) = storage_read(address=storage_addr + 1);
        let value = Uint256(low, high);
        return (value,);
    }

    // @notice This function is used to write to the storage of the account.
    // @param storage_addr The storage address, which is hash_felts(cast(Uint256, felt*)) of the Uint256 storage key.

    // @param value The value to store.
    func write_storage{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        bitwise_ptr: BitwiseBuiltin*,
    }(storage_addr: felt, value: Uint256) {
        // Write State
        storage_write(address=storage_addr + 0, value=value.low);
        storage_write(address=storage_addr + 1, value=value.high);
        return ();
    }

    // @notice This function is used to read the nonce from storage.
    // @return nonce The current nonce of the contract account.
    func get_nonce{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
        nonce: felt
    ) {
        return Account_nonce.read();
    }

    // @notice This function sets the account nonce.
    // @param new_nonce The new nonce value.
    func set_nonce{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        new_nonce: felt
    ) {
        Account_nonce.write(new_nonce);
        return ();
    }

    // @notice Writes an array of valid jumpdests indexes to storage.
    // @param jumpdests_len The length of the jumpdests array.
    // @param jumpdests The jumpdests array.
    func write_jumpdests{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        jumpdests_len: felt, jumpdests: felt*
    ) {
        // Recursively store the jumpdests.
        Internals.write_jumpdests(
            jumpdests_len=jumpdests_len, jumpdests=jumpdests, iteration_size=1
        );
        return ();
    }

    // @notice Checks if the jump destination at the given index is valid.
    // @param index The index of the jump destination.
    // @return is_valid 1 if the jump destination is valid, 0 otherwise.
    func is_valid_jumpdest{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        index: felt
    ) -> felt {
        alloc_locals;
        let (base_address) = Account_valid_jumpdests.addr();
        let index_address = base_address + index;

        let syscall = [cast(syscall_ptr, StorageRead*)];
        assert syscall.request = StorageReadRequest(
            selector=STORAGE_READ_SELECTOR, address=index_address
        );
        %{ syscall_handler.storage_read(segments=segments, syscall_ptr=ids.syscall_ptr) %}
        let response = syscall.response;
        tempvar syscall_ptr = syscall_ptr + StorageRead.SIZE;
        tempvar value = response.value;

        return value;
    }

    // @notice Gets the code hash of the account.
    // @return code_hash The code hash of the account.
    func get_code_hash{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        ) -> Uint256 {
        let (code_hash) = Account_code_hash.read();
        return code_hash;
    }

    // @notice Sets the code hash of the account.
    // @param code_hash The new code hash.
    func set_code_hash{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        code_hash: Uint256
    ) {
        Account_code_hash.write(code_hash);
        return ();
    }

    // @notice Execute a starknet call.
    // @dev Used when executing a Cairo Precompile. Used to preserve the caller address.
    // @param to The address to call.
    // @param function_selector The function selector to call.
    // @param calldata_len The length of the calldata array.
    // @param calldata The calldata for the call.
    // @return retdata_len The length of the return data array.
    // @return retdata The return data from the call.
    // @return success 1 if the call was successful, 0 otherwise.
    func execute_starknet_call{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        to: felt, function_selector: felt, calldata_len: felt, calldata: felt*
    ) -> (retdata_len: felt, retdata: felt*, success: felt) {
        alloc_locals;
        let (kakarot_address) = Ownable_owner.read();
        let (helpers_class) = IKakarot.get_cairo1_helpers_class_hash(kakarot_address);
        // Note: until Starknet v0.13.4, the transaction will always fail if the call reverted.
        // Post starknet v0.13.4, it will be possible to handle failures in contract calls.
        // Currently, `new_call_contract_syscall` is implemented to panic if the call reverted.
        // Manual changes to the implementation in the Cairo1Helpers class will be needed to handle call reverts.
        let (success, retdata_len, retdata) = ICairo1Helpers.library_call_new_call_contract_syscall(
            class_hash=helpers_class,
            to=to,
            selector=function_selector,
            calldata_len=calldata_len,
            calldata=calldata,
        );
        return (retdata_len, retdata, success);
    }
}

namespace Internals {
    // @notice Asserts that the caller is the account itself.
    func assert_only_self{syscall_ptr: felt*}() {
        let (this) = get_contract_address();
        let (caller) = get_caller_address();
        with_attr error_message("Only the account itself can call this function") {
            assert caller = this;
        }
        return ();
    }

    // @notice Store the bytecode of the contract.
    // @param bytecode_len The length of the bytecode.
    // @param bytecode The bytecode of the contract.
    func write_bytecode{syscall_ptr: felt*}(bytecode_len: felt, bytecode: felt*) {
        alloc_locals;

        if (bytecode_len == 0) {
            return ();
        }

        tempvar value = 0;
        tempvar address = 0;
        tempvar syscall_ptr = syscall_ptr;
        tempvar bytecode_len = bytecode_len;
        tempvar count = BYTES_PER_FELT;

        body:
        let value = [ap - 5];
        let address = [ap - 4];
        let syscall_ptr = cast([ap - 3], felt*);
        let bytecode_len = [ap - 2];
        let count = [ap - 1];
        let initial_bytecode_len = [fp - 4];
        let bytecode = cast([fp - 3], felt*);

        tempvar value = value * 256 + bytecode[initial_bytecode_len - bytecode_len];
        tempvar address = address;
        tempvar syscall_ptr = syscall_ptr;
        tempvar bytecode_len = bytecode_len - 1;
        tempvar count = count - 1;

        jmp cond if bytecode_len != 0;
        jmp store;

        cond:
        jmp body if count != 0;

        store:
        assert [cast(syscall_ptr, StorageWrite*)] = StorageWrite(
            selector=STORAGE_WRITE_SELECTOR, address=address, value=value
        );
        %{ syscall_handler.storage_write(segments=segments, syscall_ptr=ids.syscall_ptr) %}
        tempvar value = 0;
        tempvar address = address + 1;
        tempvar syscall_ptr = syscall_ptr + StorageWrite.SIZE;
        tempvar bytecode_len = bytecode_len;
        tempvar count = BYTES_PER_FELT;

        jmp body if bytecode_len != 0;

        return ();
    }

    // @notice Store the jumpdests of the contract.
    // @dev This function can be used by either passing an array of valid jumpdests,
    // or a dict that only contains valid entries (i.e. no invalid index has been read).
    // @param jumpdests_len The length of the valid jumpdests.
    // @param jumpdests The jumpdests of the contract. Can be an array of valid indexes or a dict.
    // @param iteration_size The size of the object we are iterating over.
    func write_jumpdests{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        jumpdests_len: felt, jumpdests: felt*, iteration_size: felt
    ) {
        alloc_locals;

        if (jumpdests_len == 0) {
            return ();
        }

        let (local base_address) = Account_valid_jumpdests.addr();
        local pedersen_ptr: HashBuiltin* = pedersen_ptr;
        local range_check_ptr = range_check_ptr;
        tempvar syscall_ptr = syscall_ptr;
        tempvar jumpdests = jumpdests;
        tempvar remaining = jumpdests_len;

        body:
        let syscall_ptr = cast([ap - 3], felt*);
        let jumpdests = cast([ap - 2], felt*);
        let remaining = [ap - 1];
        let base_address = [fp];
        let iteration_size = [fp - 3];

        let index_to_store = [jumpdests];
        tempvar storage_address = base_address + index_to_store;

        assert [cast(syscall_ptr, StorageWrite*)] = StorageWrite(
            selector=STORAGE_WRITE_SELECTOR, address=storage_address, value=1
        );
        %{ syscall_handler.storage_write(segments=segments, syscall_ptr=ids.syscall_ptr) %}
        tempvar syscall_ptr = syscall_ptr + StorageWrite.SIZE;
        tempvar jumpdests = jumpdests + iteration_size;
        tempvar remaining = remaining - 1;

        jmp body if remaining != 0;

        return ();
    }

    // @notice Load the bytecode of the contract in the specified array.
    // @param bytecode_len The length of the bytecode.
    // @return bytecode The bytecode of the contract.
    func load_bytecode{syscall_ptr: felt*, range_check_ptr}(bytecode_len: felt) -> (
        bytecode: felt*
    ) {
        alloc_locals;

        let (local bytecode: felt*) = alloc();
        local bound = 256;
        local base = 256;

        if (bytecode_len == 0) {
            return (bytecode=bytecode);
        }

        let (local chunk_counts, local remainder) = unsigned_div_rem(bytecode_len, BYTES_PER_FELT);

        tempvar remaining_bytes = bytecode_len;
        tempvar range_check_ptr = range_check_ptr;
        tempvar address = 0;
        tempvar syscall_ptr = syscall_ptr;
        tempvar value = 0;
        tempvar count = 0;

        read:
        let remaining_bytes = [ap - 6];
        let range_check_ptr = [ap - 5];
        let address = [ap - 4];
        let syscall_ptr = cast([ap - 3], felt*);
        let value = [ap - 2];
        let count = [ap - 1];

        let syscall = [cast(syscall_ptr, StorageRead*)];
        assert syscall.request = StorageReadRequest(
            selector=STORAGE_READ_SELECTOR, address=address
        );
        %{ syscall_handler.storage_read(segments=segments, syscall_ptr=ids.syscall_ptr) %}
        let response = syscall.response;

        let remainder = [fp + 4];
        let chunk_counts = [fp + 3];
        tempvar remaining_chunk = chunk_counts - address;
        jmp full_chunk if remaining_chunk != 0;
        tempvar count = remainder;
        jmp next;

        full_chunk:
        tempvar count = BYTES_PER_FELT;

        next:
        tempvar remaining_bytes = remaining_bytes;
        tempvar range_check_ptr = range_check_ptr;
        tempvar address = address + 1;
        tempvar syscall_ptr = syscall_ptr + StorageRead.SIZE;
        tempvar value = response.value;
        tempvar count = count;

        body:
        let remaining_bytes = [ap - 6];
        let range_check_ptr = [ap - 5];
        let address = [ap - 4];
        let syscall_ptr = cast([ap - 3], felt*);
        let value = [ap - 2];
        let count = [ap - 1];

        let base = [fp + 1];
        let bound = [fp + 2];
        let bytecode = cast([fp], felt*);
        tempvar offset = (address - 1) * BYTES_PER_FELT + count - 1;
        let output = bytecode + offset;

        // Put byte in output and assert that 0 <= byte < bound
        // See math.split_int
        %{
            memory[ids.output] = res = (int(ids.value) % PRIME) % ids.base
            assert res < ids.bound, f'split_int(): Limb {res} is out of range.'
        %}
        tempvar a = [output];
        %{
            from starkware.cairo.common.math_utils import assert_integer
            assert_integer(ids.a)
            assert 0 <= ids.a % PRIME < range_check_builtin.bound, f'a = {ids.a} is out of range.'
        %}
        assert a = [range_check_ptr];
        tempvar a = bound - 1 - a;
        %{
            from starkware.cairo.common.math_utils import assert_integer
            assert_integer(ids.a)
            assert 0 <= ids.a % PRIME < range_check_builtin.bound, f'a = {ids.a} is out of range.'
        %}
        assert a = [range_check_ptr + 1];

        tempvar value = (value - [output]) / base;
        tempvar remaining_bytes = remaining_bytes - 1;
        tempvar range_check_ptr = range_check_ptr + 2;
        tempvar address = address;
        tempvar syscall_ptr = syscall_ptr;
        tempvar value = value;
        tempvar count = count - 1;

        jmp cond if remaining_bytes != 0;

        with_attr error_message("Value is not empty") {
            assert value = 0;
        }
        let bytecode = cast([fp], felt*);
        return (bytecode=bytecode);

        cond:
        jmp body if count != 0;
        with_attr error_message("Value is not empty") {
            assert value = 0;
        }
        jmp read;
    }
}
