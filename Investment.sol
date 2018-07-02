pragma solidity ^0.4.13;

contract Owned {
    address public owner;
    address public newOwner;

    function Owned() {
        owner = msg.sender;
    }

    modifier onlyOwner {
        assert(msg.sender == owner);
        _;
    }

    function transferOwnership(address _newOwner) public onlyOwner {
        require(_newOwner != owner);
        newOwner = _newOwner;
    }

    function acceptOwnership() public {
        require(msg.sender == newOwner);
        OwnerUpdate(owner, newOwner);
        owner = newOwner;
        newOwner = 0x0;
    }

    event OwnerUpdate(address _prevOwner, address _newOwner);
}

contract Curated is Owned {
    mapping (address=>bool) public curatorList;

    modifier onlyCurator {
        assert(curatorList[msg.sender]);
        _;
    }

    function addCurator(address _curatorAddress) public onlyOwner {
        require(!curatorList[_curatorAddress]);
        curatorList[_curatorAddress] = true;
        CuratorAdded(_curatorAddress);
    }
    
    function removeCurator(address _curatorAddress) public onlyOwner {
        require(curatorList[_curatorAddress]);
        curatorList[_curatorAddress] = false;
        CuratorRemoved(_curatorAddress);
    }
    
    event CuratorAdded(address _newCurator);
    event CuratorRemoved(address _oldCurator);
}

contract KycInterface {
    function isAddressVerified(address _address) public view returns (bool);
}

contract ERC20TokenInterface {
  function totalSupply() public constant returns (uint256 _totalSupply);
  function balanceOf(address _owner) public constant returns (uint256 balance);
  function transfer(address _to, uint256 _value) public returns (bool success);
  function transferFrom(address _from, address _to, uint256 _value) public returns (bool success);
  function approve(address _spender, uint256 _value) public returns (bool success);
  function allowance(address _owner, address _spender) public constant returns (uint256 remaining);

  event Transfer(address indexed _from, address indexed _to, uint256 _value);
  event Approval(address indexed _owner, address indexed _spender, uint256 _value);
}

contract InvestmentContract is Owned, Curated {

    struct ContributorData {
        bool active;
        uint contributionAmount;
        bool hasVotedForDisable;
        uint dividendsPaid;
    }
    mapping(address => ContributorData) public contributorList;
    uint public nextContributorIndex;
    mapping(uint => address) public contributorIndexes;
    uint public nextContributorToReturn;

    uint public investorClaimedCount;

    enum phase { pendingStart, started, EndedFail, EndedSucess, disabled}
    phase public investmentPhase;

    uint public maxCap;
    uint public minCap;

    uint public investmentStartTime;
    uint public investmentEndedTime;

    address public tokenAddress;
    address public kycAddress;
    uint public tokensInvested;
    uint public tokensEarned;
    uint public earnedTokensPaidOut;

    event MinCapReached(uint blockNumber);
    event MaxCapReached(uint blockNumber);
    event FundsClaimed(address athlete, uint _value, uint blockNumber);
    event InvestmentMade(address _investor, uint _amount, uint _contributionAmount);
    event TokensEarned(address _sender, uint _amount);
    event DividendsClaimed(address _sender, uint _amount, uint _dividendsPaid);
    event DisableVote(address _contributor, uint _contributionAmount);

    uint public athleteCanClaimPercent;
    uint public tick;
    uint public lastClaimed;
    uint public athleteAlreadyClaimed;
    address public athlete;
    uint public withdrawFee;
    uint public dividendFee;
    address public feeWallet;

    uint public tokensVotedForDisable;

    string public contractLink;
    bytes public contractHash;

    function InvestmentContract(address _tokenAddress,
                                uint _minCap,
                                uint _maxCap,
                                uint _investmentsStartTime,
                                uint _investmentsEndedTime,
                                uint _athleteCanClaimPercent,
                                uint _tick,
                                address _athlete,
                                uint _withdrawFee,
                                uint _dividendFee,
                                address _feeWallet,
                                bytes _contractHash) {
        tokenAddress = _tokenAddress;
        minCap = _minCap;
        maxCap = _maxCap;
        investmentStartTime = _investmentsStartTime;
        investmentEndedTime = _investmentsEndedTime;
        investmentPhase = phase.pendingStart;
        contractHash = _contractHash;
        require(_athleteCanClaimPercent <= 100);
        athleteCanClaimPercent = _athleteCanClaimPercent;
        tick = _tick;
        athlete = _athlete;
        require(_withdrawFee <= 100);
        withdrawFee = _withdrawFee;
        require(_dividendFee <= 100);
        dividendFee = _dividendFee;
        feeWallet = _feeWallet;
    }

    function receiveApproval(address _from, uint256 _value, address _to, bytes _extraData) public {
        require(_to == tokenAddress);
        require(_value != 0);

        address sender;

        if(!KycInterface(kycAddress).isAddressVerified(_from)) {
            revert();
        }

        sender = _from;

        if (investmentPhase == phase.pendingStart) {
            if (now >= investmentStartTime) {
                investmentPhase = phase.started;
            } else {
                revert();
            }
        }

        if(investmentPhase == phase.started) {
            if (now > investmentEndedTime){
                if(tokensInvested >= minCap){
                    investmentPhase = phase.EndedSucess;
                }else{
                    investmentPhase = phase.EndedFail;
                }
            }else{
                uint tokensToTake = processTransaction(sender, _value);
                InvestmentMade(sender, tokensToTake, contributorList[sender].contributionAmount);
                ERC20TokenInterface(tokenAddress).transferFrom(_from, address(this), tokensToTake);
            }
        }else{
            if (investmentPhase == phase.EndedSucess){
                require(msg.sender == athlete);
                tokensEarned += _value;
                investorClaimedCount = 0;
                ERC20TokenInterface(tokenAddress).transferFrom(_from, address(this), _value);
                TokensEarned(sender, _value);
            } else {
                revert();
            }
        }
    }

    function processTransaction(address _from, uint _value) internal returns (uint) {
        uint valueToProcess = 0;
        if (tokensInvested + _value >= maxCap) {
            valueToProcess = maxCap - tokensInvested;
            investmentPhase = phase.EndedSucess;
            MaxCapReached(block.number);
        } else {
            valueToProcess = _value;
            if (tokensInvested < minCap && tokensInvested + valueToProcess >= minCap) {
                MinCapReached(block.number);
            }
        }
        if (!contributorList[_from].active) {
            contributorList[_from].active = true;
            contributorList[_from].contributionAmount = valueToProcess;
            contributorIndexes[nextContributorIndex] = _from;
            nextContributorIndex++;
        }else{
            contributorList[_from].contributionAmount += valueToProcess;
        }
        tokensInvested += valueToProcess;
        return valueToProcess;
    }

    function manuallyProcessTransaction(address _from, uint _value) onlyCurator public {
        require(_value != 0);
        require(ERC20TokenInterface(tokenAddress).balanceOf(address(this)) >= _value + (tokensInvested - athleteAlreadyClaimed) + (tokensEarned - earnedTokensPaidOut));

        if (investmentPhase == phase.pendingStart) {
            if (now >= investmentStartTime) {
                investmentPhase = phase.started;
            } else {
                ERC20TokenInterface(tokenAddress).transfer(_from, _value);
            }
        }

        if(investmentPhase == phase.started) {
            uint tokensToTake = processTransaction(_from, _value);
            InvestmentMade(_from, tokensToTake, contributorList[_from].contributionAmount);
            ERC20TokenInterface(tokenAddress).transfer(_from, _value - tokensToTake);
        }else{
            ERC20TokenInterface(tokenAddress).transfer(_from, _value);
        }
    }

    function salvageTokensFromContract(address _tokenAddress, address _to, uint _amount) onlyOwner public {
        require(_tokenAddress != tokenAddress || (_tokenAddress == tokenAddress && ERC20TokenInterface(tokenAddress).balanceOf(address(this)) >= _amount + tokensInvested + tokensEarned));
        ERC20TokenInterface(_tokenAddress).transfer(_to, _amount);
    }

    function claimFunds() public {
        require(investmentPhase == phase.EndedSucess);
        require(athleteAlreadyClaimed < tokensInvested);
        require(athlete == msg.sender);
        if (lastClaimed == 0) {
            lastClaimed = now;
        } else {
            require(lastClaimed <= now);
        }
        uint claimAmount = (athleteCanClaimPercent * tokensInvested) / 100;
        if (athleteAlreadyClaimed + claimAmount >= tokensInvested) {
            claimAmount = tokensInvested - athleteAlreadyClaimed;

        }
        athleteAlreadyClaimed += claimAmount;
        lastClaimed += tick;
        uint fee = (claimAmount * withdrawFee) / 100;
        ERC20TokenInterface(tokenAddress).transfer(athlete, claimAmount - fee);
        ERC20TokenInterface(tokenAddress).transfer(feeWallet, fee);
        FundsClaimed(athlete, claimAmount, block.number);
    }

    function claimDividends() public {
        require(contributorList[msg.sender].contributionAmount != 0);
        require(contributorList[msg.sender].dividendsPaid < ((contributorList[msg.sender].contributionAmount * tokensEarned) / tokensInvested));

        uint amountToSend;
        if (investorClaimedCount < nextContributorIndex - 1 ) {
            amountToSend = ((contributorList[msg.sender].contributionAmount * tokensEarned) / tokensInvested) - contributorList[msg.sender].dividendsPaid;
            investorClaimedCount += 1;
        } else {
            amountToSend = tokensEarned - earnedTokensPaidOut;
            investorClaimedCount = 0;
        }
        uint fee = (amountToSend * dividendFee) / 100;
        ERC20TokenInterface(tokenAddress).transfer(msg.sender, amountToSend - fee);
        ERC20TokenInterface(tokenAddress).transfer(feeWallet, fee);
        contributorList[msg.sender].dividendsPaid += amountToSend;
        earnedTokensPaidOut += amountToSend;
        DividendsClaimed(msg.sender, amountToSend, contributorList[msg.sender].dividendsPaid);
    }

    function voteForDisable() public {
        require(investmentPhase == phase.EndedSucess);
        require(contributorList[msg.sender].active);
        require(!contributorList[msg.sender].hasVotedForDisable);

        tokensVotedForDisable += contributorList[msg.sender].contributionAmount;
        contributorList[msg.sender].hasVotedForDisable = true;
        DisableVote(msg.sender, contributorList[msg.sender].contributionAmount);
        if (tokensVotedForDisable >= tokensInvested/2) {
            investmentPhase = phase.disabled;
        }
    }

    function batchReturnTokensIfFailed(uint _numberOfReturns) public {
        require(investmentPhase == phase.EndedFail);
        require(nextContributorToReturn != nextContributorIndex - 1);
        address currentParticipantAddress;
        uint contribution;
        for (uint cnt = 0; cnt < _numberOfReturns; cnt++) {
            currentParticipantAddress = contributorIndexes[nextContributorToReturn];
            if (currentParticipantAddress == 0x0) {
                return;
            }
            contribution = contributorList[currentParticipantAddress].contributionAmount;
            ERC20TokenInterface(tokenAddress).transfer(currentParticipantAddress, contribution);
            nextContributorToReturn += 1;
        }
    }

    function batchReturnTokensIfDisabled(uint _numberOfReturns) public {
        require(investmentPhase == phase.disabled);
        require(nextContributorToReturn != nextContributorIndex - 1);
        address currentParticipantAddress;
        uint contribution;
        for (uint cnt = 0; cnt < _numberOfReturns; cnt++) {
            currentParticipantAddress = contributorIndexes[nextContributorToReturn];
            if (currentParticipantAddress == 0x0) {
                return;
            }
            contribution = (contributorList[currentParticipantAddress].contributionAmount * (tokensInvested - athleteAlreadyClaimed)) / tokensInvested;
            ERC20TokenInterface(tokenAddress).transfer(currentParticipantAddress, contribution);
            nextContributorToReturn += 1;
        }
    }

    function getSaleFinancialData() public constant returns(uint,uint){
        return (tokensInvested, maxCap);
    }

    function getClaimedFinancialData() public constant returns(uint,uint){
        return (athleteAlreadyClaimed, tokensInvested);
    }

    function setKycAddress(address _newAddress) onlyOwner public {
        kycAddress = _newAddress;
    }

    function killContract() public onlyOwner {
        selfdestruct(owner);
    }

    function setContractLink(string _contractLink) onlyOwner {
        contractLink = _contractLink;
    }
}