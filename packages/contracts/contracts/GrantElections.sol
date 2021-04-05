pragma solidity >=0.7.0 <=0.8.3;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./IStaking.sol";
import "./IBeneficiaryRegistry.sol";

contract GrantElections {
  using SafeMath for uint256;

  struct Vote {
    address voter;
    address beneficiary;
    uint256 weight;
  }

  enum ElectionTerm {Monthly, Quarterly, Yearly}
  enum ElectionState {Registration, Voting, Closed}

  uint256 constant ONE_DAY = 86400; // seconds in 1 day

  struct Election {
    Vote[] votes;
    mapping(address => bool) registeredBeneficiaries;
    address[] registeredBeneficiariesList;
    ElectionTerm electionTerm;
    ElectionState electionState;
    ElectionConfiguration electionConfiguration;
    uint256 startTime;
    bool exists;
  }

  struct ElectionConfiguration {
    uint8 ranking;
    uint8 awardees;
    bool useChainLinkVRF;
    uint256 registrationPeriod;
    uint256 votingPeriod;
    uint256 cooldownPeriod;
  }

  // mapping of election terms and beneficiary total votes
  Election[3] public elections;
  mapping(ElectionTerm => mapping(address => uint256)) beneficiaryVotes;
  mapping(ElectionTerm => ElectionConfiguration) electionConfigurations;
  mapping(ElectionTerm => mapping(uint8 => address)) electionRanking;

  ElectionConfiguration[3] public electionDefaults;

  IStaking staking;
  IBeneficiaryRegistry beneficiaryRegistry;

  event BeneficiaryRegistered(address _beneficiary, ElectionTerm _term);
  event UserVoted(address _user, ElectionTerm _term);
  event ElectionInitialized(ElectionTerm _term, uint256 _startTime);

  constructor(IStaking _staking, IBeneficiaryRegistry _beneficiaryRegistry) {
    staking = _staking;
    beneficiaryRegistry = _beneficiaryRegistry;

    _setDefaults();
  }

  // todo: mint POP for caller to incentivize calling function
  function initialize(ElectionTerm _grantTerm) public {
    uint8 _term = uint8(_grantTerm);
    Election storage _election = elections[_term];

    if (_election.exists == true) {
      require(
        _election.electionState == ElectionState.Closed,
        "election not yet closed"
      );
      require(
        _election.electionConfiguration.cooldownPeriod >=
          block.timestamp.sub(_election.startTime),
        "can't start new election, not enough time elapsed since last election"
      );
    }

    delete elections[_term];

    Election storage e = elections[_term];
    e.electionConfiguration = electionDefaults[_term];
    e.electionState = ElectionState.Registration;
    e.electionTerm = _grantTerm;
    e.startTime = block.timestamp;
    e.exists = true;

    emit ElectionInitialized(e.electionTerm, e.startTime);
  }

  function getElectionMetadata(ElectionTerm _grantTerm)
    public
    view
    returns (
      Vote[] memory votes_,
      ElectionTerm term_,
      address[] memory registeredBeneficiaries_,
      ElectionState state_,
      uint8[2] memory awardeesRanking_,
      bool useChainLinkVRF_,
      uint256[3] memory periods_,
      uint256 startTime_
    )
  {
    Election storage e = elections[uint8(_grantTerm)];

    votes_ = e.votes;
    term_ = e.electionTerm;
    registeredBeneficiaries_ = e.registeredBeneficiariesList;
    state_ = e.electionState;
    awardeesRanking_ = [
      e.electionConfiguration.awardees,
      e.electionConfiguration.ranking
    ];
    useChainLinkVRF_ = e.electionConfiguration.useChainLinkVRF;
    periods_ = [
      e.electionConfiguration.cooldownPeriod,
      e.electionConfiguration.registrationPeriod,
      e.electionConfiguration.votingPeriod
    ];
    startTime_ = e.startTime;
  }

  function getRegisteredBeneficiaries(ElectionTerm _term)
    external
    returns (address[] memory)
  {
    return elections[uint8(_term)].registeredBeneficiariesList;
  }

  function getCurrentRanking(ElectionTerm _term)
    external
    view
    returns (address[] memory)
  {
    uint8 _rankingSize = elections[uint8(_term)].electionConfiguration.ranking;
    address[] memory _ranking = new address[](_rankingSize);
    for (uint8 i = 0; i < _rankingSize; i++) {
      _ranking[i] = electionRanking[_term][i];
    }
    return _ranking;
  }

  /**
   * todo: use POP for bond
   * todo: check beneficiary is not registered for another non-closed election
   * todo: check beneficiary is not currently awarded a grant
   */
  function registerForElection(address _beneficiary, ElectionTerm _grantTerm)
    public
  {
    uint8 _term = uint8(_grantTerm);
    require(
      elections[_term].electionState == ElectionState.Registration,
      "election not open for registration"
    );
    require(
      beneficiaryRegistry.beneficiaryExists(_beneficiary),
      "address is not eligible for registration"
    );

    elections[_term].registeredBeneficiaries[_beneficiary] = true;
    elections[_term].registeredBeneficiariesList.push(_beneficiary);

    emit BeneficiaryRegistered(_beneficiary, _grantTerm);
  }

  function _isEligibleBeneficiary(address _beneficiary, ElectionTerm _term)
    public
    view
    returns (bool)
  {
    return
      elections[uint8(_term)].registeredBeneficiaries[_beneficiary] &&
      beneficiaryRegistry.beneficiaryExists(_beneficiary);
  }

  function refreshElectionState(ElectionTerm _electionTerm) public {
    Election storage election = elections[uint8(_electionTerm)];
    if (
      block.timestamp >=
      election
        .startTime
        .add(election.electionConfiguration.registrationPeriod)
        .add(election.electionConfiguration.votingPeriod)
    ) {
      election.electionState = ElectionState.Closed;
    } else if (
      block.timestamp >=
      election.startTime.add(election.electionConfiguration.registrationPeriod)
    ) {
      election.electionState = ElectionState.Voting;
    } else if (block.timestamp >= election.startTime) {
      election.electionState = ElectionState.Registration;
    }
  }

  function vote(
    address[] memory _beneficiaries,
    uint8[] memory _voiceCredits,
    ElectionTerm _electionTerm
  ) public {
    Election storage election = elections[uint8(_electionTerm)];
    require(_voiceCredits.length > 0, "Voice credits are required");
    require(_beneficiaries.length > 0, "Beneficiaries are required");
    refreshElectionState(_electionTerm);
    require(
      election.electionState == ElectionState.Voting,
      "Election not open for voting"
    );

    uint256 _usedVoiceCredits = 0;
    uint256 _stakedVoiceCredits = staking.getVoiceCredits(msg.sender);

    require(_stakedVoiceCredits > 0, "must have voice credits from staking");

    for (uint8 i = 0; i < _beneficiaries.length; i++) {
      // todo: consider skipping iteration instead of throwing since if a beneficiary is removed from the registry during an election, it can prevent votes from being counted
      require(
        _isEligibleBeneficiary(_beneficiaries[i], _electionTerm),
        "ineligible beneficiary"
      );

      _usedVoiceCredits = _usedVoiceCredits.add(_voiceCredits[i]);
      uint256 _sqredVoiceCredits = sqrt(_voiceCredits[i]);

      Vote memory _vote =
        Vote({
          voter: msg.sender,
          beneficiary: _beneficiaries[i],
          weight: _sqredVoiceCredits
        });

      election.votes.push(_vote);
      beneficiaryVotes[_electionTerm][_beneficiaries[i]] = beneficiaryVotes[
        _electionTerm
      ][_beneficiaries[i]]
        .add(_sqredVoiceCredits);
      _recalculateRanking(_electionTerm, _beneficiaries[i], _sqredVoiceCredits);
    }
    require(
      _usedVoiceCredits <= _stakedVoiceCredits,
      "Insufficient voice credits"
    );
  }

  function _recalculateRanking(
    ElectionTerm _electionTerm,
    address _beneficiary,
    uint256 weight
  ) internal {
    Election storage _election = elections[uint8(_electionTerm)];
    if (
      weight >
      beneficiaryVotes[_electionTerm][
        electionRanking[_electionTerm][
          _election.electionConfiguration.ranking - 1
        ]
      ]
    ) {
      // If weight is bigger than the last in the ranking for the election term, take its position
      electionRanking[_electionTerm][
        _election.electionConfiguration.ranking - 1
      ] = _beneficiary;
    } else {
      // Otherwise, no need to recalculate ranking
      return;
    }

    // traverse inverted ranking
    for (uint8 i = _election.electionConfiguration.ranking; i > 0; i--) {
      // if the votes are higher than the next one in the ranking, swap them
      if (
        beneficiaryVotes[_electionTerm][electionRanking[_electionTerm][i]] >
        beneficiaryVotes[_electionTerm][electionRanking[_electionTerm][i - 1]]
      ) {
        (
          electionRanking[_electionTerm][i],
          electionRanking[_electionTerm][i - 1]
        ) = (
          electionRanking[_electionTerm][i - 1],
          electionRanking[_electionTerm][i]
        );
      }
    }
  }

  function _setDefaults() internal {
    ElectionConfiguration storage monthlyDefaults =
      electionDefaults[uint8(ElectionTerm.Monthly)];
    monthlyDefaults.awardees = 1;
    monthlyDefaults.ranking = 3;
    monthlyDefaults.useChainLinkVRF = true;
    monthlyDefaults.votingPeriod = 7 * ONE_DAY;
    monthlyDefaults.registrationPeriod = 7 * ONE_DAY;
    monthlyDefaults.cooldownPeriod = 21 * ONE_DAY;

    ElectionConfiguration storage quarterlyDefaults =
      electionDefaults[uint8(ElectionTerm.Quarterly)];
    quarterlyDefaults.awardees = 2;
    quarterlyDefaults.ranking = 5;
    quarterlyDefaults.useChainLinkVRF = true;
    quarterlyDefaults.votingPeriod = 14 * ONE_DAY;
    quarterlyDefaults.registrationPeriod = 14 * ONE_DAY;
    quarterlyDefaults.cooldownPeriod = 83 * ONE_DAY;

    ElectionConfiguration storage yearlyDefaults =
      electionDefaults[uint8(ElectionTerm.Yearly)];
    yearlyDefaults.awardees = 3;
    yearlyDefaults.ranking = 7;
    yearlyDefaults.useChainLinkVRF = true;
    yearlyDefaults.votingPeriod = 30 * ONE_DAY;
    yearlyDefaults.registrationPeriod = 30 * ONE_DAY;
    yearlyDefaults.cooldownPeriod = 358 * ONE_DAY;
  }

  function sqrt(uint256 y) internal pure returns (uint256 z) {
    if (y > 3) {
      z = y;
      uint256 x = y / 2 + 1;
      while (x < z) {
        z = x;
        x = (y / x + x) / 2;
      }
    } else if (y != 0) {
      z = 1;
    }
  }
}
