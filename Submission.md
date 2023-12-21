# Axiom Submission

Please use `forge build --via-ir` and `forge test --via-ir`. Opted not to refactor since its not the focus.

## Compound's GovernorBravoDelegateG2

Replace the current on-chain read of voting power by checking voting power against a provided merkle root.

Currently, GovernorBravoDelegateG2 utilises on-chain read of voting power via `getPriorVotes`. This function essentially returns the voting power of a specified address at some specified block number.
Voting power is a crucial component of the following 3 functions:

1. `propose`
2. `cancel`
3. `castVoteInternal` (and its dependent functions)

### `propose()`

Presently, a proposer has to meet the `proposalThreshold` in terms of voting power to be able to make a proposal.
This is enforced by a require statement in `propose`, where the function caller's voting power in the prior block is checked.

```solidity
require(comp.getPriorVotes(msg.sender, sub256(block.number, 1)) > proposalThreshold || isWhitelisted(msg.sender), "GovernorBravo::propose: proposer votes below proposal threshold");
```

> Whitelisted proposers do not need to meet proposalThreshold

### `castVoteInternal()`

In `castVoteInternal`, `getPriorVotes` returns a voter's voting power as per the proposal's start block.

```solidity
uint96 votes = comp.getPriorVotes(voter, proposal.startBlock);
```

A proposal's start block is calculated as follows: `(proposal.startBlock + votingDelay)`, `votingDelay` is a storage variable defined in `GovernorBravoDelegateStorageV1`.

### `cancel()`

A proposer can cancel his own proposal without any concern of voting power checks. If some other address calls `cancel`, there will be voting power checks made upon the proposal's proposer.
In such a case, for successful cancellation, crucially the proposer's voting power must have fallen below the `proposalThreshold` (amongst some other checks as well), as per the prior block.

> Whitelisted proposers can only be cancelled by guardians, if they fall below the proposalThreshold

## Using merkle roots

Now, if we wanted to use merkle roots to check voting power instead, we would need several merkle roots, not just one.

Let me give a concrete example. Assume a proposal would be made at block.number = 100. We would then need the following merkle roots:
(Assume votingDelay = 5)

1. merkleRoot at block.number = 100 - 1 = 99 (proposer's voting power check)
2. merkleRoot at block.number = 100 + votingDelay = 105  (voter's voting power check)
3. merkleRoot at block.number = 100 + delta (cancel's voting power check)

Where delta is an arbitrary value reflecting the cancellation period from when the proposal was made as per Compound's governance process. This means that we would need a series of merkle roots starting from block.number 99 to whatever block.number that would be the end of the cancellation period.

From an actual implementation perspective, this means that when `propose` or `cancel` are called, the merkle root for the prior block must be either made available (via Axiom callback) or have been already stored and retrievable on-chain via a mapping: `mapping (uint256 blockNumber => bytes32 merkleRoot) public merkleRoots;` by some other method.

In this fork, we will assume an axiom client is used to update the mapping. Essentially, every time a proposal is to be made, a script must be ran to submit a query to Axiom, the corresponding callback received, and the merkleRoot mapping updated so that the voting power check within the propose function is supported. This would similarly apply for cancelling a proposal and voting for it. If the mapping has not been updated, it will return `bytes32(0)` for the root, which result in a revert.

### Changes with proposer and voter experience

This would change the voter and proposer experience in that, they cannot interact with the contract directly and must do so from a front-end. From a proposer's POV, when he clicks the propose button on the front-end, firstly an Axiom query is fired off, and upon successfully receiving the callback, his transaction would then be submitted. The underlying assumption here is that this can be done with minimum delay, honouring the prior block requirement.

Put differently, if the callback takes too long, by the time the transaction is submitted there might a few blocks in slippage. Given that implementation of the merkle root delivery mechanism is out of scope, we will not dwell on this possibility.

Another key difference in the experience is the introduction of `votes` and `proof` as input parameters for `propose`, `cancel`, `castVoteInternal`. These two are required to conduct verification against the merkle root. However, we cannot expect the end-user to be cognizant of their votes or generate their required proof. This will have to be handled by the front-end or server-side. Which means a copy of the merkle tree for each relevant block must be stored off-chain, together with the list of unhashed leaves. This is a sensible expectation given the premise was to use merkle roots to begin with.

There is the concern that the off-chain copy of the tree or the list of votes per address might be altered. The solution here would be an axiom circuit that can pull the relevant data from said block, and offer a trusted and accurate reference on-demand.

With regards to proposal execution (proposing, reviewing, voting, cancellation), nothing significantly changes - the flow remains the same. The core component of calling Comp for a voting power is replaced by an internal call to the merkleRoot mapping to verify if the votes submitted as input param is true.

## Contract changes

Changes in the code have been marked out the with `@audit ` tag.

### GovernorBravoDelegateG2Fork.sol

Instead of referencing `comp.getPriorVotes(voter, proposal.startBlock)` reference merkle root.

Functions affected:

- `propose` (ensures proposer has sufficient votes)
- `castVoteInternal` (get votes)
- `cancel` (checks if proposer has insufficient votes; therefore cancel)
- `castVote`
- `castVoteWithReason`
- `castVoteBySig`
- `_initiate` (define axiomClient for callback)

For these functions, their inputs have been modified the new method of verification. Existing interfaces will have to be updated accordingly, as the function signatures would be different.

Functions added:

- `updateMerkleMapping`
- `getPriorVotes`
- `verify`

## GovernorBravoDelegateStorageV2

Add mapping `merkleRoots` and address `axiomClient`
We choose to extend the storage in StorageV2 to minimise interface differences between the original and fork.

### Other design thoughts

I followed Compound's syntax and coding as closely as possible, with respect to error strings, variable names, variable declarations.
However, here are some other considerations I would have preferred to have done.

- Use of uint256 explicitly instead of uint.
- Refactor require statements with long strings. keep under 32 characters to honor 1 EVM word. Alternatively, refactor to use custom errors.
- Splitting up require statements to save gas.

## Testing Plan

The testing focus will be upon the modified `GovernorBravoDelegateFork` contract - all other contracts are assumed to be battle-tested as no modifications were made to them.  
The following functions are of specific focus: `castVoteInternal` (and all dependent functions), `propose`, `cancel`.
We assume axiom client works as intended.

Employ a state inheritance testing approach. This approach is also known as Branching Tree Technique (BTT), which is a useful framework to map out execution paths and consider contract states.
We will map out all the states the contract can be in, starting from its deployment state.

- Each state is encapsulated by an abstract contract
- The abstract contract will serve to set-up the state as it should be
- Each abstract contract will be paired and inherited by a standard contract which will contain the test functions encompassing that state.
- Test functions should typically lead with negative tests and then positive tests with a final state transition test, before moving to the next state.

> A more concrete implementation of this testing approach can be seen at: https://github.com/calnix/staking-pools/blob/main/test/StakingPoolIndex/StakingPoolndex_LinearTest.t.sol

### Testing flow
----
#### StateZero
(Just deployed. sanity checks)
+ testMerkleTree(): merkle tree/root related functions are functioning correctly
+ testProposalCount(): proposalCount should be 1, as per initial setup
- testPublicCannotUpdateMerkleMapping(): Other arbitrary addresses cannnot update merkle mapping
+ testAxiomClientCanUpdateMapping(): only AxiomClient can update merkle mapping

#### StateProposal
(proposer will make proposal. simulate axiom callback for prior block's root)
- testUsersCannotPropose(): User cannot propose - insufficient votes
- testUsersCannotSpoofVotes(): User cannot spoof merkle verification to submit proposal
+ testProposerCanPropose(): Proposer: create proposal w/ dummy variables

#### StateProposalReview
(no voting can occur)
- testUsersCannotVote(): proposal in review; cannot vote
- testCannotCancelIfWhitelistedProposer():  whitelisted proposers can't be cancelled for falling below proposal threshold (by normal users)
+ testProposerCanCancel(): issuer should be able to self-cancel
+ testWhitelistedCanCancel(): whitelisted proposers can be cancelled by guardians, if proposalThreshold is not met
+ testUserCanCancelNormalProposer(): a standard user can cancel standard proposers, if proposalThreshold is not met

#### StateVotingActive
(proposal state updated; fast forward to voting period)

(simulate axiom callback to update voting weights for the block: proposal.startBlock + votingDelay)
- testCannotStackVotes(): same user cannot vote twice
- testUserCannotSpoofVotes: user cannot spoof their voting power
+ testUserCanVote(): ensure votes param passed is verified and votes are recorded

We can continue this pattern all the way to completion, StateProposalVotingEnds, StateProposalExecuted and so forth; and we should do so in a less constrained setting, to map out the entire flow from deployment to each of the possible end states: execution, cancellation, voting failed, etc. This will ensure that the changes introduced do not somehow unintentionally create a loophole or vulnerability in other unmodified contracts, due to some unforeseen effects.

> I would have liked to have drafted out the full state flow and corresponding tests for each of them, but could not due to the time constraint.
> A very good reference for testing structure and format would be Sablier v2: https://github.com/sablier-labs/v2-core/tree/main/test

### Beyond internal testing

1. Run slither for static analysis: detects vulnerabilities, bad practices, and provides detailed reports. Slither can find a wide range of vulnerabilities, including reentrancy attacks, timestamp dependency vulnerabilities, and integer overflow vulnerabilities. Regardless of false-positives, at the least it can be informational.
2. Run mutation testing: vertigo-rs (https://github.com/RareSkills/vertigo-rs). This is to check the quality of the test suite.
3. Run echinda: for fuzzing and invariant testing (can be used with foundry).
4. Build a testing suite to carry out testing against a mainnet fork. This allows us to cut as close as possible to reality.

We can add-on a number of other tools here like Manticore/Mythril for symbolic execution to enhance code coverage - but given that newer and better security tools are continually being introduced (like Olypmix), we should take care to not go overboard with automated tools. A complimentary blend of tools should be used for maximum coverage and assessment.

Keep in mind that automated tooling are not perfect and can miss vulnerabilities, usually with regards to business logic. Hence audits are an important part of security.