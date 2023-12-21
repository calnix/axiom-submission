// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";

import {AxiomClient} from "../src/AxiomClient.sol";
import {GovernorBravoDelegateFork} from "../src/GovernorBravoDelegateG2Fork.sol";
import {GovernorBravoDelegator} from "../src/GovernorBravoDelegator.sol";
import {TimelockInterface, GovernorBravoDelegateStorageV2, GovernorBravoDelegateStorageV1, GovernorBravoDelegatorStorage, GovernorBravoEvents} from "../src/GovernorBravoInterfaces.sol";

import {GovernorAlpha} from "./GovernorAlpha.sol";
import {Timelock} from "./Timelock.sol";
import {Merkle} from "./Merkle.sol";


abstract contract StateZero is Test {
    using stdStorage for StdStorage;

    // contracts
    AxiomClient public axiom;
    Merkle public merkle;

    GovernorBravoDelegateFork public implementation;
    GovernorBravoDelegator public proxy;
    GovernorBravoDelegateFork public gBravo;
    
    GovernorAlpha public gAlpha;
    Timelock public timelock;

    //RBAC addresses
    address public admin;
    address public guardian;

    // users
    address public userA;
    address public userB;
    address public userC;
    address public proposer;

    uint96 public votesA;
    uint96 public votesB;
    uint96 public votesC;
    uint96 public votesProposer;

    // Dummy variables for GBravo
    uint256 public votingPeriod = 6660;
    uint256 public votingDelay = 1;
    uint256 public proposalThreshold = 70000e18;
    GovernorBravoDelegateStorageV1.Proposal public newProposal;

    // Dummy variables for Axiom Client
    address public dummyQueryAddress = makeAddr("dummyQueryAddress");
    uint64 public dummySourceChainId = uint64(1);
    bytes32 public dummyQuerySchema = bytes32("dummyQuerySchema");

    function setUp() public virtual {
        
        // users
        userA = address(0xA);
        userB = address(0xB);
        userC = address(0xC);
        proposer = makeAddr("proposer");

        admin = makeAddr("admin");
        guardian = makeAddr("guardian");

        // voting power
        votesA = 10e18;
        votesB = 15e18;
        votesC = 20e18;
        votesProposer = uint96(proposalThreshold + 10e18);

        //deploy contracts
        vm.startPrank(admin);
        
        timelock = new Timelock(admin, 2 days);
        gAlpha = new GovernorAlpha(address(timelock), guardian);

        implementation = new GovernorBravoDelegateFork();
        proxy = new GovernorBravoDelegator(address(timelock), admin, address(implementation), votingPeriod, votingDelay, proposalThreshold);
        gBravo = GovernorBravoDelegateFork(address(proxy));

        axiom = new AxiomClient(dummyQueryAddress, dummySourceChainId, dummyQuerySchema, address(gBravo));
        merkle = new Merkle();

        vm.stopPrank();

        // timelock.setPendingAdmin: typically must QueueTransaction and execute
        // we will use cheatcodes since this a limited scope setup
        vm.prank(address(timelock));
        timelock.setPendingAdmin(address(proxy));

        // init: GovernorAlpha::proposalCount() = 0
        // change to 1, so that GovernorBravo not active test clears
        stdstore
        .target(address(gAlpha))
        .sig(gAlpha.proposalCount.selector)
        .checked_write(1);

        vm.prank(admin);
        gBravo._initiate(address(gAlpha), address(axiom));

    }

    function generateRoot() public returns (bytes32, bytes32[][] memory) {
        address[] memory members = new address[](4);
        members[0] = userA;
        members[1] = userB;
        members[2] = userC;
        members[3] = proposer;

        uint256[] memory votes = new uint256[](4);
        votes[0] = votesA;
        votes[1] = votesB;
        votes[2] = votesC;
        votes[3] = votesProposer;
        
        (bytes32 root, bytes32[][] memory tree) = merkle.constructTree(members, votes);

        return (root, tree);
    }

}

//Note: Post-deployment sanity checks
contract StateZeroTest is StateZero {

    function testMerkleTree() public {
        console2.log("Test merkle tree functions");

        (bytes32 root, bytes32[][] memory tree) = generateRoot();
        // gen. proofs
        bytes32[] memory proof = merkle.createProof(3, tree);
        bytes32[] memory wrongProof = merkle.createProof(0, tree);

        //test proofs
        bytes32 leaf = ~keccak256(abi.encode(proposer, votesProposer));

        bool isVerified = gBravo.verify(leaf, root, proof);
        bool isNotVerified = gBravo.verify(leaf, root, wrongProof);

        assertEq(isVerified, true);
        assertEq(isNotVerified, false);
    }

    function testProposalCount() public {
        console2.log("Proposal count should start from 1");
        assertEq(gBravo.proposalCount(), 1);
    }

    function testPublicCannotUpdateMerkleMapping() public {
        console2.log("Other arbitrary addresses cannnot update merkle mapping");
        
        vm.prank(userA);
        vm.expectRevert("GovernorBravo::updateMerkleMapping: Only axiom caller");
        gBravo.updateMerkleMapping(1, bytes32("someRoot"));
    }

    function testAxiomClientCanUpdateMapping() public {
        console2.log("only AxiomClient can update merkle mapping");
        
        // generate root
        (bytes32 root, ) = generateRoot();

        // set block.number = 1
        vm.warp(1);

        vm.prank(address(axiom));
        gBravo.updateMerkleMapping(block.number - 1, root);
        
        // block.numer = 0
        assertEq(gBravo.merkleRoots(block.number - 1), root);
        console2.log(block.number - 1);
    }
}

//Note: Proposal will be made in this block. Root will be updated for prior block
abstract contract StateProposal is StateZero {

    uint256 public proposerPriorBlock;
    bytes32[] public proposalProof;

    // dummy proposal vars
    address[] public targets = [makeAddr("testProposal")];
    uint256[] public values = [uint256(1)];
    string[] public signatures = ["testProposal"];
    bytes[] public calldatas = [bytes("testProposal")];
    string public description = "testProposal";

    function setUp() public virtual override {
        super.setUp();
        
        // set block.number = 1
        vm.warp(1);

        //simulate Axiom client callback update
        //create root and update mapping
        (bytes32 root, bytes32[][] memory tree) = generateRoot();        
        vm.prank(address(axiom));
        gBravo.updateMerkleMapping(block.number - 1, root);
        
        proposerPriorBlock = block.number - 1;
        // gen. proofs
        proposalProof = merkle.createProof(3, tree);
    }
}

contract StatePriorProposal is StateProposal {

    function testUsersCannotPropose() public {
        console2.log("User cannot propose - insufficient votes");

        assertEq(gBravo.proposalCount(), 1);

        vm.prank(userA);

        vm.expectRevert("GovernorBravo::propose: proposer votes below proposal threshold");
        gBravo.propose(targets, values, signatures, calldatas, description, votesA, proposalProof);
    }

    function testUsersCannotSpoofVotes() public {
        console2.log("User cannot spoof merkle verification");

        assertEq(gBravo.proposalCount(), 1);

        vm.prank(userA);

        vm.expectRevert("GovernorBravo::propose: Merkle verification failed");
        gBravo.propose(targets, values, signatures, calldatas, description, votesProposer, proposalProof);
    }

    function testProposerCanPropose() public {
        console2.log("Proposer: create proposal w/ dummy variables");

        assertEq(gBravo.proposalCount(), 1);

        vm.prank(proposer);
        gBravo.propose(targets, values, signatures, calldatas, description, votesProposer, proposalProof);

        // proposal count should have incremented
        assertEq(gBravo.proposalCount(), 2);
        assertEq(gBravo.latestProposalIds(proposer), 2);
    }
}