// SPDX-License-Identifier: GPL-3.0-only;
pragma solidity 0.5.17;

import "@openzeppelin/upgrades/contracts/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@windingtree/org.id/contracts/ERC165/ERC165.sol";
import "@windingtree/org.id/contracts/OrgIdInterface.sol";
import "./DirectoryInterface.sol";
import { IArbitrable, IArbitrator } from "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

/* solhint-disable max-line-length */

/**
 *  @title ArbitrableDirectory
 *  @dev A Directory contract arbitrated by Kleros.
 *  Organizations are added or removed based on a ruling given by the arbitrator contract.
 *  NOTE: This contract trusts that the Arbitrator is honest and will not reenter or modify its costs during a call.
 *  The arbitrator must support appeal period.
 */
contract ArbitrableDirectory is DirectoryInterface, IArbitrable, IEvidence, ERC165, Initializable {

    using CappedMath for uint;

    /* Enums */

    enum Party {
        None, // Party per default when there is no challenger or requester. Also used for unconclusive ruling.
        Requester, // Party that makes a request to add the organization.
        Challenger // Party that challenges the request.
    }

    enum Status {
        Absent, // The organization is not registered and doesn't have an open request.
        RegistrationRequested, // The organization has an open request.
        WithdrawalRequested, // The organization made a withdrawal request.
        Challenged, // The organization has been challenged.
        Disputed, // The challenge has been disputed.
        Registered // The organization is registered.
    }

    /* Structs */

    struct Organization {
        bytes32 ID; // The ID of the organization.
        Status status; // The current status of the organization.
        address requester; // The address that made the last registration request. It is possible to have multiple requests if the organization is added, then removed and then added again etc.
        uint256 lastStatusChange; // The time when the organization's status was updated. Only applies to the statuses that are time-sensitive, to track Execution and Response timeouts. Doesn't apply to the withdrawal timeouts.
        uint256 lifStake; // The amount of Lif tokens, deposited by the requester when the request was made.
        Challenge[] challenges; // List of challenges made for the organization.
        uint256 withdrawalRequestTime; // The time when the withdrawal request was made.
    }

    struct Challenge {
        bool disputed; // Whether the challenge has been disputed or not.
        uint256 disputeID; // The ID of the dispute raised in arbitrator contract, if any.
        bool resolved; // True if the request was executed or any raised disputes were resolved.
        address payable challenger; // The address that challenged the organization.
        Round[] rounds; // Tracks each round of a dispute.
        Party ruling; // The final ruling given by the arbitrator, if any.
        IArbitrator arbitrator; // The arbitrator trusted to solve a dispute for this challenge.
        bytes arbitratorExtraData; // The extra data for the trusted arbitrator of this challenge.
        uint256 metaEvidenceID; // The meta evidence to be used in a dispute for this case.
    }

    // Arrays with 3 elements map with the Party enum for better readability:
    // - 0: is unused, matches `Party.None`.
    // - 1: for `Party.Requester`.
    // - 2: for `Party.Challenger`.
    struct Round {
        uint[3] paidFees; // Tracks the fees paid for each Party in this round.
        bool[3] hasPaid; // True if the Party has fully paid its fee in this round.
        uint256 feeRewards; // Sum of reimbursable fees and stake rewards available to the parties that made contributions to the side that ultimately wins a dispute.
        mapping(address => uint[3]) contributions; // Maps contributors to their contributions for each side.
    }

    /* Storage */

    OrgIdInterface public orgId; // An instance of the ORG.ID smart contract.
    ERC20 public lif; // Lif token instance.

    string internal segment; // Segment name, i.e. hotel, airline.
    address public governor; // The address that can make changes to the parameters of the contract.

    IArbitrator public arbitrator; // The arbitrator contract.
    bytes public arbitratorExtraData; // Extra data for the arbitrator contract.

    uint256 public constant RULING_OPTIONS = 2; // The amount of non 0 choices the arbitrator can give.

    uint256 public requesterDeposit; // The amount of Lif tokens in base units a requester must deposit in order to open a request to add the organization.
    uint256 public challengeBaseDeposit; // The base deposit to challenge the organization. Also the base deposit to accept the challenge. In wei.

    uint256 public executionTimeout; // The time after which the organization can be added to the directory if not challenged.
    uint256 public responseTimeout; // The time the requester has to accept the challenge, or he will lose otherwise. Note that any other address can accept the challenge on requester's behalf.
    uint256 public withdrawTimeout; // The time after which it becomes possible to execute the withdrawal request and withdraw the Lif stake. The organization can still be challenged during this time, but not after.

    uint256 public metaEvidenceUpdates; // The number of times the meta evidence has been updated. Is used to track the latest meta evidence ID.

    // Multipliers are in basis points.
    uint256 public winnerStakeMultiplier; // Multiplier for calculating the fee stake paid by the party that won the previous round.
    uint256 public loserStakeMultiplier; // Multiplier for calculating the fee stake paid by the party that lost the previous round.
    uint256 public sharedStakeMultiplier; // Multiplier for calculating the fee stake that must be paid in the case where arbitrator refused to arbitrate.
    uint256 public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    bytes32[] public registeredOrganizations; // Stores all added organizations.
    mapping(bytes32 => Organization) public organizationData; // Maps the organization to its data. organizationData[_organization].
    mapping(bytes32 => uint256) public organizationsIndex; // Maps the organization to its index in the registeredOrganizations array. organizationsIndex[_organization].
    mapping(address => mapping(uint256 => bytes32)) public arbitratorDisputeIDToOrg; // Maps a dispute ID to the organization ID. arbitratorDisputeIDToOrg[_arbitrator][_disputeID].
    bytes32[] public requestedOrganizations; // Stores all organizations in Requested status
    mapping(bytes32 => uint256) public requestedIndex; // Maps requested organization to its index in the requestedOrganizations array. requestedIndex[_organization].

    /* Modifiers */

    modifier onlyGovernor {require(msg.sender == governor, "The caller must be the governor."); _;}

    /* Events */

    /** @dev Event triggered every time segment value is changed.
     *  @param _previousSegment Previous name of the segment.
     *  @param _newSegment New name of the segment.
     */
    event SegmentChanged(string _previousSegment, string _newSegment);

    /** @dev Event triggered when a request to add an organization is made.
     *  @param _organization The organization that was added.
     */
    event OrganizationSubmitted(bytes32 indexed _organization);

    /** @dev Event triggered every time organization is added.
     *  @param _organization The organization that was added.
     *  @param _index Organization's index in the array.
     */
    event OrganizationAdded(bytes32 indexed _organization, uint256 _index);

    /** @dev Event triggered every time organization is removed.
     *  @param _organization The organization that was removed.
     */
    event OrganizationRemoved(bytes32 indexed _organization);

    /* External and Public */

    // ************************ //
    // *      Governance      * //
    // ************************ //

    /**
     *  @dev Initializer for upgradeable contracts.
     *  @param _governor The trusted governor of this contract.
     *  @param _segment The segment name.
     *  @param _orgId The address of the ORG.ID contract.
     *  @param _lif The address of the Lif token.
     *  @param _arbitrator Arbitrator to resolve potential disputes. The arbitrator is trusted to support appeal periods, not to reenter and to behave honestly.
     *  @param _arbitratorExtraData Extra data for the trusted arbitrator contract.
     *  @param _metaEvidence The URI of the meta evidence object.
     *  @param _requesterDeposit The amount of Lif tokens in base units required to make a request.
     *  @param _challengeBaseDeposit The base deposit to challenge a request or to accept the challenge.
     *  @param _executionTimeout The time after which the organization will be registered if not challenged.
     *  @param _responseTimeout The time the requester has to answer to challenge.
     *  @param _withdrawTimeout The time after which it becomes possible to execute the withdrawal request.
     *  @param _stakeMultipliers Multipliers of the arbitration cost in basis points (see MULTIPLIER_DIVISOR) as follows:
     *  - The multiplier applied to each party's fee stake for a round when there is no winner/loser in the previous round.
     *  - The multiplier applied to the winner's fee stake for the subsequent round.
     *  - The multiplier applied to the loser's fee stake for the subsequent round.
     */
    function initialize(
        address _governor,
        string memory _segment,
        OrgIdInterface _orgId,
        ERC20 _lif,
        IArbitrator _arbitrator,
        bytes memory _arbitratorExtraData,
        string memory _metaEvidence,
        uint256 _requesterDeposit,
        uint256 _challengeBaseDeposit,
        uint256 _executionTimeout,
        uint256 _responseTimeout,
        uint256 _withdrawTimeout,
        uint[3] memory _stakeMultipliers
    ) public initializer {
        setInterfaces();
        emit MetaEvidence(metaEvidenceUpdates, _metaEvidence);
        governor = _governor;
        segment = _segment;
        orgId = _orgId;
        lif = _lif;

        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
        requesterDeposit = _requesterDeposit;
        challengeBaseDeposit = _challengeBaseDeposit;
        executionTimeout = _executionTimeout;
        responseTimeout = _responseTimeout;
        withdrawTimeout = _withdrawTimeout;
        sharedStakeMultiplier = _stakeMultipliers[0];
        winnerStakeMultiplier = _stakeMultipliers[1];
        loserStakeMultiplier = _stakeMultipliers[2];

        organizationsIndex[bytes32(0)] = registeredOrganizations.length;
        registeredOrganizations.push(bytes32(0));
        requestedIndex[bytes32(0)] = requestedOrganizations.length;
        requestedOrganizations.push(bytes32(0));
    }

    /**
     * @dev Allows the governor of the contract to change the segment name.
     * @param _segment The new segment name.
     */
    function setSegment(string calldata _segment) external onlyGovernor {
        emit SegmentChanged(segment, _segment);
        segment = _segment;
    }

    /**
     * @dev Change the Lif token amount required to make a request.
     * @param _requesterDeposit The new Lif token amount required to make a request.
     */
    function changeRequesterDeposit(uint256 _requesterDeposit) external onlyGovernor {
        requesterDeposit = _requesterDeposit;
    }

    /**
     * @dev Change the base amount required as a deposit to challenge the organization or to accept the challenge.
     * @param _challengeBaseDeposit The new base amount of wei required to challenge or to accept the challenge.
     */
    function changeChallengeBaseDeposit(uint256 _challengeBaseDeposit) external onlyGovernor {
        challengeBaseDeposit = _challengeBaseDeposit;
    }

    /**
     * @dev Change the duration of the timeout after which the organization can be registered if not challenged.
     * @param _executionTimeout The new duration of the execution timeout.
     */
    function changeExecutionTimeout(uint256 _executionTimeout) external onlyGovernor {
        executionTimeout = _executionTimeout;
    }

    /**
     * @dev Change the duration of the time the requester has to accept the challenge.
     * @param _responseTimeout The new duration of the response timeout.
     */
    function changeResponseTimeout(uint256 _responseTimeout) external onlyGovernor {
        responseTimeout = _responseTimeout;
    }

    /**
     * @dev Change the duration of the time after which it becomes possible to execute the withdrawal request.
     * @param _withdrawTimeout The new duration of the withdraw timeout.
     */
    function changeWithdrawTimeout(uint256 _withdrawTimeout) external onlyGovernor {
        withdrawTimeout = _withdrawTimeout;
    }

    /**
     * @dev Change the proportion of arbitration fees that must be paid as fee stake by parties when there is no winner or loser.
     * @param _sharedStakeMultiplier Multiplier of arbitration fees that must be paid as fee stake. In basis points.
     */
    function changeSharedStakeMultiplier(uint256 _sharedStakeMultiplier) external onlyGovernor {
        sharedStakeMultiplier = _sharedStakeMultiplier;
    }

    /**
     * @dev Change the proportion of arbitration fees that must be paid as fee stake by the winner of the previous round.
     * @param _winnerStakeMultiplier Multiplier of arbitration fees that must be paid as fee stake. In basis points.
     */
    function changeWinnerStakeMultiplier(uint256 _winnerStakeMultiplier) external onlyGovernor {
        winnerStakeMultiplier = _winnerStakeMultiplier;
    }

    /**
     * @dev Change the proportion of arbitration fees that must be paid as fee stake by the party that lost the previous round.
     * @param _loserStakeMultiplier Multiplier of arbitration fees that must be paid as fee stake. In basis points.
     */
    function changeLoserStakeMultiplier(uint256 _loserStakeMultiplier) external onlyGovernor {
        loserStakeMultiplier = _loserStakeMultiplier;
    }

    /**
     * @dev Change the arbitrator to be used for disputes that may be raised. The arbitrator is trusted to support appeal periods and not reenter.
     * @param _arbitrator The new trusted arbitrator to be used in disputes.
     * @param _arbitratorExtraData The extra data used by the new arbitrator.
     */
    function changeArbitrator(IArbitrator _arbitrator, bytes calldata _arbitratorExtraData) external onlyGovernor {
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
    }

    /**
     * @dev Update the meta evidence used for disputes.
     * @param _metaEvidence The meta evidence to be used for future disputes.
     */
    function changeMetaEvidence(string calldata _metaEvidence) external onlyGovernor {
        metaEvidenceUpdates++;
        emit MetaEvidence(metaEvidenceUpdates, _metaEvidence);
    }

    // ****************************** //
    // *   Requests and Challenges  * //
    // ****************************** //

    /**
     * @dev Make a request to add an organization to the directory. Requires a Lif deposit.
     * @param _organization The ID of the organization.
     */
    function requestToAdd(bytes32 _organization) external {
        Organization storage organization = organizationData[_organization];
        require(organization.status == Status.Absent, "Directory: The organization must be either registered or registering.");

        // Get the organization info from the ORG.ID registry.
        (bool exists,,,,,,, address orgOwner, address director, bool isActive, bool isDirectorshipAccepted) = orgId.getOrganization(_organization);
        require(exists, "Directory: Organization not found.");
        require(orgOwner == msg.sender || (director == msg.sender && isDirectorshipAccepted), "Directory: Only organization owner or director can add the organization.");
        require(isActive, "Directory: Only enabled organizations can be added.");

        organization.ID = _organization;
        organization.status = Status.RegistrationRequested;
        organization.requester = msg.sender;
        organization.lastStatusChange = now;
        organization.lifStake = requesterDeposit;
        require(lif.transferFrom(msg.sender, address(this), requesterDeposit), "Directory: The token transfer must not fail.");

        requestedIndex[_organization] = requestedOrganizations.length;
        requestedOrganizations.push(_organization);

        emit OrganizationSubmitted(_organization);
    }

    /**
     * @dev Challenge the organization. Accept enough ETH to cover the deposit, reimburse the rest.
     * @param _organization The ID of the organization to challenge.
     * @param _evidence A link to evidence using its URI. Ignored if not provided.
     */
    function challengeOrganization(bytes32 _organization, string calldata _evidence) external payable {
        Organization storage organization = organizationData[_organization];
        require(
            organization.status == Status.RegistrationRequested || organization.status == Status.Registered || organization.status == Status.WithdrawalRequested,
            "Directory: The organization should be either registered or registering."
        );
        if (organization.status == Status.WithdrawalRequested)
            require(now - organization.withdrawalRequestTime <= withdrawTimeout, "Directory: Time to challenge the withdrawn organization has passed.");
        Challenge storage challenge = organization.challenges[organization.challenges.length++];
        organization.status = Status.Challenged;
        organization.lastStatusChange = now;

        challenge.challenger = msg.sender;
        challenge.arbitrator = arbitrator;
        challenge.arbitratorExtraData = arbitratorExtraData;
        challenge.metaEvidenceID = metaEvidenceUpdates;

        Round storage round = challenge.rounds[challenge.rounds.length++];

        uint256 arbitrationCost = challenge.arbitrator.arbitrationCost(challenge.arbitratorExtraData);
        uint256 totalCost = arbitrationCost.addCap(challengeBaseDeposit);
        contribute(round, Party.Challenger, msg.sender, msg.value, totalCost);
        require(round.paidFees[uint256(Party.Challenger)] >= totalCost, "Directory: You must fully fund your side.");
        round.hasPaid[uint256(Party.Challenger)] = true;

        if (bytes(_evidence).length > 0)
            emit Evidence(challenge.arbitrator, uint256(keccak256(abi.encodePacked(_organization, organization.challenges.length))), msg.sender, _evidence);
    }

    /**
     * @dev Answer to the challenge and create a dispute. Accept enough ETH to cover the deposit, reimburse the rest.
     * @param _organization The ID of the organization which challenge to accept.
     * @param _evidence A link to evidence using its URI. Ignored if not provided.
     */
    function acceptChallenge(bytes32 _organization, string calldata _evidence) external payable {
        Organization storage organization = organizationData[_organization];
        require(organization.status == Status.Challenged, "Directory: The organization should have status Challenged.");
        require(now - organization.lastStatusChange <= responseTimeout, "Directory: Time to accept the challenge has passed.");

        Challenge storage challenge = organization.challenges[organization.challenges.length - 1];
        organization.status = Status.Disputed;
        Round storage round = challenge.rounds[0];
        uint256 arbitrationCost = challenge.arbitrator.arbitrationCost(challenge.arbitratorExtraData);
        uint256 totalCost = arbitrationCost.addCap(challengeBaseDeposit);
        contribute(round, Party.Requester, msg.sender, msg.value, totalCost);
        require(round.paidFees[uint256(Party.Requester)] >= totalCost, "Directory: You must fully fund your side.");
        round.hasPaid[uint256(Party.Requester)] = true;

        // Raise a dispute.
        challenge.disputeID = challenge.arbitrator.createDispute.value(arbitrationCost)(RULING_OPTIONS, challenge.arbitratorExtraData);
        arbitratorDisputeIDToOrg[address(challenge.arbitrator)][challenge.disputeID] = _organization;
        challenge.disputed = true;
        challenge.rounds.length++;
        round.feeRewards = round.feeRewards.subCap(arbitrationCost);

        uint256 evidenceGroupID = uint256(keccak256(abi.encodePacked(_organization, organization.challenges.length)));
        emit Dispute(challenge.arbitrator, challenge.disputeID, challenge.metaEvidenceID, evidenceGroupID);

        if (bytes(_evidence).length > 0)
            emit Evidence(challenge.arbitrator, evidenceGroupID, msg.sender, _evidence);
    }

    /**
     * @dev Execute an unchallenged request if the execution timeout has passed, or execute the challenge if it wasn't accepted during response timeout.
     * @param _organization The ID of the organization.
     */
    function executeTimeout(bytes32 _organization) external {
        Organization storage organization = organizationData[_organization];
        require(
            organization.status == Status.RegistrationRequested || organization.status == Status.Challenged,
            "Directory: The organization must have a pending status and not be disputed."
        );

        if (organization.status == Status.RegistrationRequested) {
            require(now - organization.lastStatusChange > executionTimeout, "Directory: Time to challenge the request must pass.");
            organization.status = Status.Registered;
            if (organizationsIndex[_organization] == 0) {
                organizationsIndex[_organization] = registeredOrganizations.length;
                registeredOrganizations.push(_organization);
                removeOrganization(_organization, true); // Refreshing requested organizations list
                emit OrganizationAdded(_organization, organizationsIndex[_organization]);
            }
        } else {
            require(now - organization.lastStatusChange > responseTimeout, "Directory: Time to respond to the challenge must pass.");
            organization.status = Status.Absent;
            organization.withdrawalRequestTime = 0;
            Challenge storage challenge = organization.challenges[organization.challenges.length - 1];
            challenge.resolved = true;
            uint256 stake = organization.lifStake;
            organization.lifStake = 0;
            removeOrganization(_organization, true); // Refreshing requested organizations list
            removeOrganization(_organization, false);
            require(lif.transfer(challenge.challenger, stake), "Directory: The token transfer must not fail.");
        }
    }

    /**
     * @dev Take up to the total amount required to fund a side of an appeal. Reimburse the rest. Create an appeal if both sides are fully funded.
     * @param _organization The ID of the organization.
     * @param _side The recipient of the contribution.
     */
    function fundAppeal(bytes32 _organization, Party _side) external payable {
        require(_side == Party.Requester || _side == Party.Challenger, "Directory: Invalid party.");
        require(organizationData[_organization].status == Status.Disputed, "Directory: The organization must have an open dispute.");
        Challenge storage challenge = organizationData[_organization].challenges[organizationData[_organization].challenges.length - 1];
        (uint256 appealPeriodStart, uint256 appealPeriodEnd) = challenge.arbitrator.appealPeriod(challenge.disputeID);
        require(
            now >= appealPeriodStart && now < appealPeriodEnd,
            "Directory: Contributions must be made within the appeal period."
        );

        uint256 multiplier;
        Party winner = Party(challenge.arbitrator.currentRuling(challenge.disputeID));
        Party loser;
        if (winner == Party.Requester)
            loser = Party.Challenger;
        else if (winner == Party.Challenger)
            loser = Party.Requester;
        require(
            _side != loser || (now-appealPeriodStart < (appealPeriodEnd-appealPeriodStart)/2),
            "Directory: The loser must contribute during the first half of the period.");

        if (_side == winner)
            multiplier = winnerStakeMultiplier;
        else if (_side == loser)
            multiplier = loserStakeMultiplier;
        else
            multiplier = sharedStakeMultiplier;

        Round storage round = challenge.rounds[challenge.rounds.length - 1];
        uint256 appealCost = challenge.arbitrator.appealCost(challenge.disputeID, challenge.arbitratorExtraData);
        uint256 totalCost = appealCost.addCap((appealCost.mulCap(multiplier)) / MULTIPLIER_DIVISOR);
        contribute(round, _side, msg.sender, msg.value, totalCost);

        if (round.paidFees[uint256(_side)] >= totalCost)
            round.hasPaid[uint256(_side)] = true;

        // Raise appeal if both sides are fully funded.
        if (round.hasPaid[uint256(Party.Challenger)] && round.hasPaid[uint256(Party.Requester)]) {
            challenge.arbitrator.appeal.value(appealCost)(challenge.disputeID, challenge.arbitratorExtraData);
            challenge.rounds.length++;
            round.feeRewards = round.feeRewards.subCap(appealCost);
        }
    }

    /**
     * @dev Reimburse contributions if no disputes were raised. If a dispute was raised, send the fee stake rewards and reimbursements proportionally to the contributions made to the winner of a dispute.
     * @param _beneficiary The address that made contributions.
     * @param _organization The ID of the organization.
     * @param _challenge The challenge from which to withdraw.
     * @param _round The round from which to withdraw.
     */
    function withdrawFeesAndRewards(address payable _beneficiary, bytes32 _organization, uint256 _challenge, uint256 _round) external {
        Organization storage organization = organizationData[_organization];
        Challenge storage challenge = organization.challenges[_challenge];
        Round storage round = challenge.rounds[_round];
        require(challenge.resolved, "Directory: The challenge must be resolved.");

        uint256 reward;
        if (!round.hasPaid[uint256(Party.Requester)] || !round.hasPaid[uint256(Party.Challenger)]) {
            // Reimburse if not enough fees were raised to appeal the ruling.
            reward = round.contributions[_beneficiary][uint256(Party.Requester)] + round.contributions[_beneficiary][uint256(Party.Challenger)];
        } else if (challenge.ruling == Party.None) {
            // Reimburse unspent fees proportionally if there is no winner or loser.
            uint256 rewardRequester = round.paidFees[uint256(Party.Requester)] > 0
                ? (round.contributions[_beneficiary][uint256(Party.Requester)] * round.feeRewards) / (round.paidFees[uint256(Party.Challenger)] + round.paidFees[uint256(Party.Requester)])
                : 0;
            uint256 rewardChallenger = round.paidFees[uint256(Party.Challenger)] > 0
                ? (round.contributions[_beneficiary][uint256(Party.Challenger)] * round.feeRewards) / (round.paidFees[uint256(Party.Challenger)] + round.paidFees[uint256(Party.Requester)])
                : 0;

            reward = rewardRequester + rewardChallenger;
        } else {
            // Reward the winner.
            reward = round.paidFees[uint256(challenge.ruling)] > 0
                ? (round.contributions[_beneficiary][uint256(challenge.ruling)] * round.feeRewards) / round.paidFees[uint256(challenge.ruling)]
                : 0;

        }
        round.contributions[_beneficiary][uint256(Party.Requester)] = 0;
        round.contributions[_beneficiary][uint256(Party.Challenger)] = 0;

        _beneficiary.send(reward);
    }

    /**
     * @dev Make a request to remove the organization and withdraw Lif tokens from the directory. The organization is removed right away but the tokens can only be withdrawn after withdrawTimeout, to prevent frontrunning the challengers.
     * @param _organization The ID of the organization.
     */
    function makeWithdrawalRequest(bytes32 _organization) external {
        Organization storage organization = organizationData[_organization];
        require(
            organization.status == Status.RegistrationRequested || organization.status == Status.Registered,
            "Directory: The organization has wrong status."
        );
        (,,,,,,, address orgOwner, address director,, bool isDirectorshipAccepted) = orgId.getOrganization(_organization);
        require(orgOwner == msg.sender || (director == msg.sender && isDirectorshipAccepted), "Directory: Only organization owner or director can request a withdrawal.");

        organization.withdrawalRequestTime = now;
        organization.status = Status.WithdrawalRequested;
        removeOrganization(_organization, true); // Refreshing requested organizations list
        removeOrganization(_organization, false);
    }

    /**
     * @dev Withdraw all the Lif tokens deposited when the request was made.
     * @param _organization The ID of the organization to un-register.
     */
    function withdrawTokens(bytes32 _organization) external {
        Organization storage organization = organizationData[_organization];
        require(
            organization.status == Status.WithdrawalRequested,
            "Directory: The organization has wrong status."
        );
        require(now - organization.withdrawalRequestTime > withdrawTimeout, "Directory: Tokens can only be withdrawn after the timeout.");
        (,,,,,,, address orgOwner,,,) = orgId.getOrganization(_organization);
        organization.status = Status.Absent;
        organization.withdrawalRequestTime = 0;
        uint256 stake = organization.lifStake;
        organization.lifStake = 0;
        require(lif.transfer(orgOwner, stake), "Directory: The token transfer must not fail.");
    }

    /**
     * @dev Give a ruling for a dispute. Can only be called by the arbitrator. TRUSTED.
     * Accounts for the situation where the winner loses a case due to paying less appeal fees than expected.
     * @param _disputeID ID of the dispute in the arbitrator contract.
     * @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Refused to arbitrate".
     */
    function rule(uint256 _disputeID, uint256 _ruling) public {
        require(_ruling <= RULING_OPTIONS, "Directory: Invalid ruling option.");
        Party resultRuling = Party(_ruling);
        bytes32 organizationID = arbitratorDisputeIDToOrg[msg.sender][_disputeID];
        Organization storage organization = organizationData[organizationID];

        Challenge storage challenge = organization.challenges[organization.challenges.length - 1];
        Round storage round = challenge.rounds[challenge.rounds.length - 1];
        require(address(challenge.arbitrator) == msg.sender, "Directory: Only the arbitrator can give a ruling.");
        require(!challenge.resolved, "Directory: The challenge must not be resolved.");

        // If one side paid its fees, the ruling is in its favor. Note that if the other side had also paid, an appeal would have been created.
        if (round.hasPaid[uint256(Party.Requester)] == true)
            resultRuling = Party.Requester;
        else if (round.hasPaid[uint256(Party.Challenger)] == true)
            resultRuling = Party.Challenger;

        emit Ruling(IArbitrator(msg.sender), _disputeID, uint256(resultRuling));
        executeRuling(_disputeID, uint256(resultRuling));
    }

    /**
     * @dev Submit a reference to evidence. EVENT.
     * @param _organization The ID of the organization which the evidence is related to.
     * @param _evidence A link to evidence using its URI.
     */
    function submitEvidence(bytes32 _organization, string calldata _evidence) external {
        Organization storage organization = organizationData[_organization];
        require(organization.requester != address(0), "Directory: The organization never had a request.");

        uint256 evidenceGroupID = uint256(keccak256(abi.encodePacked(_organization, organization.challenges.length)));
        if (bytes(_evidence).length > 0) {
            if (organization.challenges.length > 0) {
                Challenge storage challenge = organization.challenges[organization.challenges.length - 1];
                require(!challenge.resolved, "Directory: The challenge must not be resolved.");
                emit Evidence(challenge.arbitrator, evidenceGroupID, msg.sender, _evidence);
            } else
                emit Evidence(arbitrator, evidenceGroupID, msg.sender, _evidence);
        }
    }

    /* Internal */

    /**
     * @dev Get all the registered or requested organizations.
     * @param _cursor Index of the organization from which to start querying.
     * @param _count Number of organizations to go through. Iterates until the end if set to "0" or number higher than the total number of organizations.
     * @param returnRequested Boolean flag indicated a kind of organizations either registered (false) or requested (true)
     * @return organizationsList Array of organization IDs.
     */
    function getCertainOrganizations(uint256 _cursor, uint256 _count, bool returnRequested)
        internal
        view
        returns (bytes32[] memory organizationsList)
    {
        bytes32[] storage targetOrganizations = returnRequested ? requestedOrganizations : registeredOrganizations;
        organizationsList = new bytes32[](getCertainOrganizationsCount(_cursor, _count, returnRequested));
        uint256 index;
        for (uint256 i = _cursor; i < targetOrganizations.length && (_count == 0 || i < _cursor + _count); i++) {
            if (targetOrganizations[i] != bytes32(0)) {
                organizationsList[index] = targetOrganizations[i];
                index++;
            }
        }
    }

    /**
     * @dev Return registeredOrganizations array length.
     * @param _cursor Index of the organization from which to start counting.
     * @param _count Number of organizations to go through. Iterates until the end if set to "0" or number higher than the total number of organizations.
     * @param returnRequested Boolean flag indicated a kind of organizations either registered (false) or requested (true)
     * @return count Length of the organizations array.
     */
    function getCertainOrganizationsCount(uint256 _cursor, uint256 _count, bool returnRequested)
        internal
        view
        returns (uint256 count) {
        bytes32[] storage targetOrganizations = returnRequested ? requestedOrganizations : registeredOrganizations;
        for (uint256 i = _cursor; i < targetOrganizations.length && (_count == 0 || i < _cursor + _count); i++) {
            if (targetOrganizations[i] != bytes32(0))
                count++;
        }
    }

    /**
     * @dev Remove organization from the storage
     * @param _organization The ID of the organization.
     * @param removeRequested Boolean flag indicated a kind of organizations either registered (false) or requested (true)
     */
    function removeOrganization(bytes32 _organization, bool removeRequested) internal {
        bytes32[] storage targetOrganizations = removeRequested ? requestedOrganizations : registeredOrganizations;
        mapping(bytes32 => uint256) storage targetIndex = removeRequested ? requestedIndex : organizationsIndex;
        uint256 index = targetIndex[_organization];
        if (index != 0) {
            bytes32 lastOrg = targetOrganizations[targetOrganizations.length - 1];
            targetOrganizations[index] = lastOrg;
            targetIndex[lastOrg] = index;
            targetOrganizations.length--;
            targetIndex[_organization] = 0;

            if (!removeRequested) {
                emit OrganizationRemoved(_organization);
            }
        }
    }

    /**
     * @dev Return the contribution value and remainder from available ETH and required amount.
     * @param _available The amount of ETH available for the contribution.
     * @param _requiredAmount The amount of ETH required for the contribution.
     * @return taken The amount of ETH taken.
     * @return remainder The amount of ETH left from the contribution.
     */
    function calculateContribution(uint256 _available, uint256 _requiredAmount)
        internal
        pure
        returns(uint256 taken, uint256 remainder)
    {
        if (_requiredAmount > _available)
            return (_available, 0); // Take whatever is available, return 0 as leftover ETH.
        else
            return (_requiredAmount, _available - _requiredAmount);
    }

    /**
     * @dev Make a fee contribution.
     * @param _round The round to contribute.
     * @param _side The side for which to contribute.
     * @param _contributor The contributor.
     * @param _amount The amount contributed.
     * @param _totalRequired The total amount required for this side.
     * @return The amount of appeal fees contributed.
     */
    function contribute(Round storage _round, Party _side, address payable _contributor, uint256 _amount, uint256 _totalRequired) internal returns (uint) {
        // Take up to the amount necessary to fund the current round at the current costs.
        uint256 contribution; // Amount contributed.
        uint256 remainingETH; // Remaining ETH to send back.
        (contribution, remainingETH) = calculateContribution(_amount, _totalRequired.subCap(_round.paidFees[uint256(_side)]));
        _round.contributions[_contributor][uint256(_side)] += contribution;
        _round.paidFees[uint256(_side)] += contribution;
        _round.feeRewards += contribution;

        // Reimburse leftover ETH.
        _contributor.send(remainingETH); // Deliberate use of send in order to not block the contract in case of reverting fallback.

        return contribution;
    }

    /**
     * @dev Set the list of contract interfaces supported
     */
    function setInterfaces() internal {
        DirectoryInterface dir;
        bytes4[2] memory interfaceIds = [
            // ERC165 interface: 0x01ffc9a7
            bytes4(0x01ffc9a7),

            // directory interface: 0xae54f8e1
            dir.getSegment.selector ^
            dir.getOrganizations.selector ^
            dir.getOrganizationsCount.selector
        ];
        for (uint256 i = 0; i < interfaceIds.length; i++) {
            _registerInterface(interfaceIds[i]);
        }
    }

    /**
     * @dev Execute the ruling of a dispute.
     * @param _disputeID ID of the dispute in the arbitrator contract.
     * @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Refused to arbitrate".
     */
    function executeRuling(uint256 _disputeID, uint256 _ruling) internal {
        bytes32 organizationID = arbitratorDisputeIDToOrg[msg.sender][_disputeID];
        Organization storage organization = organizationData[organizationID];
        Challenge storage challenge = organization.challenges[organization.challenges.length - 1];
        Party winner = Party(_ruling);
        uint256 stake = organization.lifStake;
        (,,,,,,, address orgOwner,,,) = orgId.getOrganization(organization.ID);
        if (winner == Party.Requester) {
            // If the organization is challenged during withdrawal process just send tokens to the orgOwner and set the status to default. The organization is not added in this case.
            if (organization.withdrawalRequestTime != 0) {
                organization.withdrawalRequestTime = 0;
                organization.status = Status.Absent;
                organization.lifStake = 0;
                require(lif.transfer(orgOwner, stake), "Directory: The token transfer must not fail.");
            } else {
                organization.status = Status.Registered;
                // Add the organization if it's not in the directory.
                if (organizationsIndex[organization.ID] == 0) {
                    organizationsIndex[organization.ID] = registeredOrganizations.length;
                    registeredOrganizations.push(organization.ID);
                    removeOrganization(organization.ID, true); // Refreshing requested organizations list
                    emit OrganizationAdded(organization.ID, organizationsIndex[organization.ID]);
                }
            }
        // Remove the organization if it is in the directory. Send Lif tokens to the challenger.
        } else if (winner == Party.Challenger) {
            organization.status = Status.Absent;
            organization.withdrawalRequestTime = 0;
            organization.lifStake = 0;
            removeOrganization(organization.ID, true); // Refreshing requested organizations list
            removeOrganization(organization.ID, false);
            require(lif.transfer(challenge.challenger, stake), "Directory: The token transfer must not fail.");
        // 0 ruling. Revert the organization to its default state.
        } else {
            if (organizationsIndex[organization.ID] == 0) {
                organization.status = Status.Absent;
                organization.withdrawalRequestTime = 0;
                organization.lifStake = 0;
                require(lif.transfer(orgOwner, stake), "Directory: The token transfer must not fail.");
            // Stake of the already registered organization stays in the contract in this case.
            } else
                organization.status = Status.Registered;
        }

        challenge.resolved = true;
        challenge.ruling = Party(_ruling);
    }

    // ************************ //
    // *       Getters        * //
    // ************************ //

    /**
     * @dev Returns a segment name.
     */
    function getSegment() public view returns (string memory) {
        return segment;
    }

    /**
     * @dev Get all the registered organizations.
     * @param _cursor Index of the organization from which to start querying.
     * @param _count Number of organizations to go through. Iterates until the end if set to "0" or number higher than the total number of organizations.
     * @return organizationsList Array of organization IDs.
     */
    function getOrganizations(uint256 _cursor, uint256 _count)
        external
        view
        returns (bytes32[] memory organizationsList)
    {
        return getCertainOrganizations(_cursor, _count, false);
    }

    /**
     * @dev Return registeredOrganizations array length.
     * @param _cursor Index of the organization from which to start counting.
     * @param _count Number of organizations to go through. Iterates until the end if set to "0" or number higher than the total number of organizations.
     * @return count Length of the organizations array.
     */
    function getOrganizationsCount(uint256 _cursor, uint256 _count)
        public
        view
        returns (uint256 count) {
        return getCertainOrganizationsCount(_cursor, _count, false);
    }

    /**
     * @dev Get all the requested organizations.
     * @param _cursor Index of the organization from which to start querying.
     * @param _count Number of organizations to go through. Iterates until the end if set to "0" or number higher than the total number of organizations.
     * @return organizationsList Array of organization IDs.
     */
    function getRequestedOrganizations(uint256 _cursor, uint256 _count)
        external
        view
        returns (bytes32[] memory organizationsList)
    {
        return getCertainOrganizations(_cursor, _count, true);
    }

    /**
     * @dev Return registeredOrganizations array length.
     * @param _cursor Index of the organization from which to start counting.
     * @param _count Number of organizations to go through. Iterates until the end if set to "0" or number higher than the total number of organizations.
     * @return count Length of the organizations array.
     */
    function getRequestedOrganizationsCount(uint256 _cursor, uint256 _count)
        public
        view
        returns (uint256 count) {
        return getCertainOrganizationsCount(_cursor, _count, true);
    }

    /**
     * @dev Get the contributions made by a party for a given round of a challenge.
     * @param _organization The ID of the organization.
     * @param _challenge The challenge to query.
     * @param _round The round to query.
     * @param _contributor The address of the contributor.
     * @return The contributions.
     */
    function getContributions(
        bytes32 _organization,
        uint256 _challenge,
        uint256 _round,
        address _contributor
    ) external view returns (uint[3] memory contributions) {
        Organization storage organization = organizationData[_organization];
        Challenge storage challenge = organization.challenges[_challenge];
        Round storage round = challenge.rounds[_round];
        contributions = round.contributions[_contributor];
    }

    /**
     * @dev Get the number of challenges of the organization.
     * @param _organization The ID of the organization.
     * @return numberOfChallenges Total number of times the organization was challenged.
     */
    function getNumberOfChallenges(bytes32 _organization)
        external
        view
        returns (
            uint256 numberOfChallenges
        )
    {
        Organization storage organization = organizationData[_organization];
        return (
            organization.challenges.length
        );
    }

    /**
     * @dev Get the number of ongoing disputes of the organization.
     * @param _organization The ID of the organization.
     * @return numberOfDisputes Total number of disputes of the organization.
     */
    function getNumberOfDisputes(bytes32 _organization)
        external
        view
        returns (
            uint256 numberOfDisputes
        )
    {
        Organization storage organization = organizationData[_organization];

        for (uint256 i = 0; i < organization.challenges.length; i++) {
            if (organizationData[_organization].challenges[i].disputed &&
                !organizationData[_organization].challenges[i].resolved) {

                numberOfDisputes++;
            }
        }
    }

    /**
     * @dev Get the information of a challenge made for the organization.
     * @param _organization The ID of the organization.
     * @param _challenge The challenge to query.
     * @return The challenge information.
     */
    function getChallengeInfo(bytes32 _organization, uint256 _challenge)
        external
        view
        returns (
            bool disputed,
            uint256 disputeID,
            bool resolved,
            address payable challenger,
            uint256 numberOfRounds,
            Party ruling,
            IArbitrator arbitrator,
            bytes memory arbitratorExtraData,
            uint256 metaEvidenceID
        )
    {
        Challenge storage challenge = organizationData[_organization].challenges[_challenge];
        return (
            challenge.disputed,
            challenge.disputeID,
            challenge.resolved,
            challenge.challenger,
            challenge.rounds.length,
            challenge.ruling,
            challenge.arbitrator,
            challenge.arbitratorExtraData,
            challenge.metaEvidenceID
        );
    }

    /**
     * @dev Get the information of a round of a challenge.
     * @param _organization The ID of the organization.
     * @param _challenge The request to query.
     * @param _round The round to be query.
     * @return The round information.
     */
    function getRoundInfo(bytes32 _organization, uint256 _challenge, uint256 _round)
        external
        view
        returns (
            bool appealed,
            uint[3] memory paidFees,
            bool[3] memory hasPaid,
            uint256 feeRewards
        )
    {
        Organization storage organization = organizationData[_organization];
        Challenge storage challenge = organization.challenges[_challenge];
        Round storage round = challenge.rounds[_round];
        return (
            _round != (challenge.rounds.length - 1),
            round.paidFees,
            round.hasPaid,
            round.feeRewards
        );
    }
}
