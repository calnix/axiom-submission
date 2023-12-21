// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {AxiomV2Client} from "axiom-v2-contracts/contracts/client/AxiomV2Client.sol";

interface GovernorBravo {
   function updateMerkleMapping(uint256 blockNumber, bytes32 merkleRoot) external;
}

contract AxiomClient is AxiomV2Client {

    bytes32 immutable QUERY_SCHEMA;
    uint64 immutable SOURCE_CHAIN_ID;
    GovernorBravo immutable governorBravo;

    constructor(address _axiomV2QueryAddress, uint64 _callbackSourceChainId, bytes32 _querySchema, address gBravo) AxiomV2Client(_axiomV2QueryAddress) {
        
        QUERY_SCHEMA = _querySchema;
        SOURCE_CHAIN_ID = _callbackSourceChainId;
        governorBravo = GovernorBravo(gBravo);
    }

    function _validateAxiomV2Call(
        AxiomCallbackType, // callbackType,
        uint64 sourceChainId,
        address, // caller,
        bytes32 querySchema,
        uint256, // queryId,
        bytes calldata // extraData
    ) internal view override {

        require(sourceChainId == SOURCE_CHAIN_ID, "Source chain ID does not match");
        require(querySchema == QUERY_SCHEMA, "Invalid query schema");
    }

    function _axiomV2Callback(
        uint64, // sourceChainId,
        address, // caller,
        bytes32, // querySchema,
        uint256, // queryId,
        bytes32[] calldata axiomResults,
        bytes calldata // extraData
    ) internal override {

        // do something with Axiom results
        uint256 merkleBlock = uint256(axiomResults[0]);
        bytes32 merkleRoot = axiomResults[1];
        
        governorBravo.updateMerkleMapping(merkleBlock, merkleRoot);
    }
}
