pragma solidity ^0.7.0;

import './Ownable.sol';

contract Genesis is Ownable {

    address public defaultMetaDao;

    bytes public defaultProxyBytecode;

    uint public launchFee;

    uint public cancellationFee;

    uint public maxWhitelistSize;

    bool public genOwnerParticipation;

    bool public disabled;

    struct Proposal {
        uint id;
        address creator;
        string title;
        uint requiredFunds;
        uint participationAmount;
        mapping(address => bool) whitelist;
        address[] addresses;
        mapping(address => uint) funds;
        uint participantCount;
        uint totalFunds;
        bool launched;
        bool cancelled;
        address metaDaoAddress;
        bytes proxyBytecode;
        address daoAddress;
    }

    uint public proposalCount;

    mapping(uint => Proposal) public proposals;

    constructor(address defaultMetaDao_, bytes memory defaultProxyBytecode_, uint launchFee_, uint cancellationFee_, uint maxWhitelistSize_, bool genOwnerParticipation_) {
        setUpgradeabilityProxyOwner(msg.sender);
        initialize(defaultMetaDao_, defaultProxyBytecode_, launchFee_, cancellationFee_, maxWhitelistSize_, genOwnerParticipation_);
    }

    function initialize(address defaultMetaDao_, bytes memory defaultProxyByteCode_, uint launchFee_, uint cancellationFee_, uint maxWhitelistSize_, bool genOwnerParticipation_) public onlyProxyOwner {
        setConfig(launchFee_, cancellationFee_, maxWhitelistSize_, genOwnerParticipation_);
        setDefaultMetaDao(defaultMetaDao_);
        setDefaultProxyBytecode(defaultProxyByteCode_);
    }

    function setConfig(uint launchFee_, uint cancellationFee_, uint maxWhitelistSize_, bool genOwnerParticipation_) public onlyProxyOwner {
        launchFee = launchFee_;
        cancellationFee = cancellationFee_;
        maxWhitelistSize = maxWhitelistSize_;
        genOwnerParticipation = genOwnerParticipation_;
    }

    function setDefaultMetaDao(address defaultMetaDao_) public onlyProxyOwner {
        defaultMetaDao = defaultMetaDao_;
    }

    function setDefaultProxyBytecode(bytes memory defaultProxyBytecode_) public onlyProxyOwner {
        defaultProxyBytecode = defaultProxyBytecode_;
    }

    function setDisabled(bool disabled_) public onlyProxyOwner {
        disabled = disabled_;
    }

    function createProposal(uint requiredFunds, uint participationAmount, string memory title, address[] memory whitelist, address metaDaoAddress, bytes memory proxyBytecode) public payable {
        require(disabled == false, "genesis is disabled");
        bytes memory tempTitle = bytes(title);
        require(tempTitle.length > 0, "title cannot be empty");
        require(whitelist.length > 0, "whitelist cannot be empty");
        require(whitelist.length <= maxWhitelistSize, "whitelist exceeds max size");
        require(participationAmount * whitelist.length >= requiredFunds, "requiredFunds is greater then the sum of participationAmount for whitelisted accounts");

        proposalCount++;

        Proposal storage p = proposals[proposalCount];
        p.id = proposalCount;
        p.creator = msg.sender;
        p.title = title;
        p.requiredFunds = requiredFunds;
        p.participationAmount = participationAmount;
        p.totalFunds = 0;
        p.metaDaoAddress = metaDaoAddress != address(0) ? metaDaoAddress : defaultMetaDao;
        p.proxyBytecode = proxyBytecode;

        for (uint i = 0; i < whitelist.length; i++) {
            p.whitelist[whitelist[i]] = true;
        }
    }

    function deposit(uint id) public payable {
        Proposal storage proposal = proposals[id];

        require(proposal.id > 0, 'proposal not found');
        require(proposal.whitelist[msg.sender], 'sender is not whitelisted');
        require(msg.value == proposal.participationAmount, 'value must equal the participation amount');

        if (proposal.funds[msg.sender] == 0) {
            proposal.participantCount++;
            proposal.addresses.push(msg.sender);
        }

        proposal.funds[msg.sender] += msg.value;
        proposal.totalFunds += msg.value;
    }

    function launch(uint id) public {
        uint gasBefore = gasleft();

        Proposal storage proposal = proposals[id];

        require(proposal.id > 0, 'proposal not found');
        require(!proposal.cancelled, 'proposal is cancelled');
        require(!proposal.launched, 'already launched');
        proposal.launched = true;
        require(proposal.totalFunds >= proposal.requiredFunds, 'insufficient funds');

        uint participantCount = proposal.participantCount;
        address owner = proxyOwner();
        if (owner != address(0) && genOwnerParticipation) {
            participantCount++;
        }

        address[] memory participants = new address[](participantCount);

        uint payerIndex = 0;
        // filter only participants that deposited funds
        for (uint i = 0; i < proposal.addresses.length; i++) {
            address addr = proposal.addresses[i];
            if (proposal.funds[addr] > 0) {
                participants[payerIndex] = addr;
                payerIndex++;
            }
        }
        if (owner != address(0) && genOwnerParticipation) {
            participants[payerIndex] = owner;
        }

        // deploy proxy, assign ownership to itself and set the dao logic contract
        bytes memory proxyBytecode = proposal.proxyBytecode.length > 0 ? proposal.proxyBytecode : defaultProxyBytecode;
        proposal.daoAddress = deployProxy(proxyBytecode, proposal.id);

        GenDaoInterface dao = GenDaoInterface(proposal.daoAddress);
        dao.initProxy(proposal.metaDaoAddress, proposal.daoAddress);
        dao.initialize(address(this), proposal.title, participants);

        if (owner != address(0) && launchFee > 0) {
            uint launchCost = proposal.totalFunds * launchFee / 100;
            proposal.totalFunds -= launchCost;
            transferTo(owner, launchCost);
        }

        // transfer collected funds to dao and refund sender for the gas
        uint gasCost = (gasBefore - gasleft() + 46004) * tx.gasprice;
        proposal.totalFunds -= gasCost;

        transferTo(proposal.daoAddress, proposal.totalFunds);

        msg.sender.transfer(gasCost);
    }

    function deployProxy(bytes memory proxyBytecode, uint salt) internal returns (address) {
        address addr;
        assembly {
            addr := create2(0, add(proxyBytecode, 0x20), mload(proxyBytecode), salt)
            if iszero(extcodesize(addr)) {
                revert(0, 0)
            }
        }
        return addr;
    }

    function cancel(uint id) public {
        Proposal storage proposal = proposals[id];

        require(proposal.id > 0, 'proposal not found');
        require(msg.sender == proposal.creator, 'only creator can cancel a proposal');
        require(!proposal.cancelled, 'already cancelled');
        require(!proposal.launched, 'already launched');

        proposal.cancelled = true;
    }

    function refund(uint id) public returns (bool) {
        Proposal storage proposal = proposals[id];

        require(proposal.id > 0, 'proposal not found');
        require(proposal.cancelled, 'not cancelled');

        uint amount = proposal.funds[msg.sender];
        require(amount > 0, 'no funds to refund');

        proposal.participantCount--;
        proposal.funds[msg.sender] = 0;
        proposal.totalFunds -= amount;

        uint refundRatio = 100;

        address owner = proxyOwner();
        if (owner != address(0) && cancellationFee > 0) {
            refundRatio -= cancellationFee;
            transferTo(owner, amount * cancellationFee / 100);
        }

        msg.sender.transfer(amount * refundRatio / 100);

        return true;
    }

    function transferTo(address to, uint value) internal {
        (bool success,) = to.call{value:value}(abi.encode());
        require(success);
    }

    function getProposal(uint id) public view returns (string memory, address, address, bool, bool, uint, uint, uint, uint) {
        Proposal storage proposal = proposals[id];
        return (
            proposal.title,
            proposal.daoAddress,
            proposal.creator,
            proposal.launched,
            proposal.cancelled,
            proposal.requiredFunds,
            proposal.participationAmount,
            proposal.totalFunds,
            proposal.participantCount
        );
    }
}

interface GenDaoInterface {
    function initProxy(address defaultImpl, address owner) external;
    function initialize(address genesisAddress_, string memory title_, address[] memory members_) external;
}
