pragma solidity 0.8.9;

// import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// import "hardhat/console.sol";

contract CreaticlesDapp is ContextUpgradeable {
    uint256 public CHOOSING_PERIOD;

    struct Request {
        address requester;
        bytes32 detailsHash;
        uint256 value;
        uint128 numberOfWinners;
        uint256 createdAt;
        uint256 expiresAt;
        bool active;
        uint256 numMintPerToken;
    }

    uint256 COMMISSION = 25;

    address payable public recipientDao;
    uint256 public numberOfRequests;
    mapping(uint256 => Request) public requests;
    address public adm;
    address public nftContractAddress;
    bool private initialized;

    address creaticles;

    //EVENTS
    event RequestCreated(
        uint256 requestId,
        address requester,
        bytes32 detailsHash,
        uint256 value,
        uint128 numberOfWinners,
        uint256 createdAt,
        uint256 expiresAt,
        bool active,
        uint256 numMintPerToken
    );
    event ProposalAccepted(
        address to,
        uint256 requestId,
        uint256[] _proposalId,
        uint256[] _tokenIds,
        string[] _tokenURLs,
        address[] _winners,
        uint256 remainingValue,
        uint256 tokenSupplies
    );
    event FundsReclaimed(uint256 requestId, address requester, uint256 amount);
    event ChoosingPeriodChanged(uint256 period);
    event CommissionChanged(uint256 commission);

    mapping(uint256 => address) public request_erc20_addresses;

    //MODIFIERS
    modifier onlyRequester(uint256 _requestId) {
        require(
            requests[_requestId].requester == msg.sender,
            "Sender is not Requester"
        );
        _;
    }
    modifier isCreaticlesNFTContract() {
        require(
            _msgSender() == nftContractAddress,
            "Only Creaticles NFT Contract has permission to call this function"
        );
        _;
    }
    modifier isAdmin() {
        require(
            _msgSender() == adm,
            "This function can only be called by an admin"
        );
        _;
    }

    //INTITIALIZER
    /**
     *
     * @param _choosingPeriod: units DAYS => used to set allowable time period for requester to choose winners
     * @param  _commission =>  (parts per thousand)
     * @param _creaticles: Creaticles's ERC20Token address
     * @param _recipientDao: DAO's address
     */
    function initialize(
        uint256 _choosingPeriod,
        uint256 _commission,
        address _creaticles,
        address payable _recipientDao
    ) public {
        require(!initialized, "Contract instance has already been initialized");
        initialized = true;
        adm = msg.sender;
        CHOOSING_PERIOD = _choosingPeriod * 1 days;
        COMMISSION = _commission;
        creaticles = _creaticles;
        recipientDao = _recipientDao;
    }

    /**
     * @param nftAddress:
     */
    function setNFTContractAddress(address nftAddress) public isAdmin {
        nftContractAddress = nftAddress;
    }

    //MUTABLE FUNCTIONS
    /**
     * @dev creates a request
     * @param _detailsHash => keccak256 hash of the metadata of the request
     * @param _numberOfWinners => the initially set number of winners. A request cannot take more winners than specified
     * @param _duration => time span of contest in seconds. After this time is up. No more proposals can be taken and the choosing period starts
     * @param _numMintPerToken => number of NFTs per winner . You can choose to mint fewer NFTs when your contest is over but you cannot mint more.
     * @param _paymentERC20Address => ERC20Address of payment
     * @param _paymentValue =>  Value of payment
     */
    function createRequest(
        bytes32 _detailsHash,
        uint16 _numberOfWinners,
        uint32 _duration,
        uint256 _numMintPerToken,
        address _paymentERC20Address,
        uint256 _paymentValue
    ) public payable returns (uint256) {
        require(_numberOfWinners > 0);
        require(_paymentValue > 0);

        uint256 _cval;
        uint256 _value;
        {
            if (_paymentERC20Address == address(0)) {
                // zero address corresponds to ethereum payment, the default
                require(msg.value == _paymentValue);
                _cval = (msg.value * COMMISSION) / 1000; // 2.5% commision
                _value = msg.value - _cval;
                recipientDao.transfer(_cval);
            } else if (_paymentERC20Address == creaticles) {
                IERC20(_paymentERC20Address).transferFrom(
                    msg.sender,
                    address(this),
                    _paymentValue
                );
                _value = _paymentValue;
            } else {
                // Here we explore additional ERC20 payment options
                IERC20(_paymentERC20Address).transferFrom(
                    msg.sender,
                    address(this),
                    _paymentValue
                );
                _cval = (_paymentValue * COMMISSION) / 1000; // 2.5% commision
                _value = _paymentValue - _cval;
                IERC20(_paymentERC20Address).transfer(recipientDao, _cval);
            }
            request_erc20_addresses[numberOfRequests] = _paymentERC20Address;

            Request storage _request = requests[numberOfRequests];
            _request.requester = msg.sender;
            _request.detailsHash = _detailsHash;
            _request.value = _value;
            _request.numberOfWinners = _numberOfWinners;
            _request.createdAt = block.timestamp;
            _request.expiresAt = block.timestamp + _duration;
            _request.active = true;
            _request.numMintPerToken = _numMintPerToken;
            numberOfRequests += 1;
        }

        emit RequestCreated(
            numberOfRequests - 1,
            msg.sender,
            _detailsHash,
            _value,
            _numberOfWinners,
            block.timestamp,
            block.timestamp + _duration,
            true,
            _numMintPerToken
        );

        return numberOfRequests - 1;
    }

    /**
     * @dev update creaticles's ERC20Token address
     * @param _token => Creaticles's ERC20Token address
     */
    function updateCreaticles(address _token) external isAdmin {
        creaticles = _token;
    }

    /**
     * @dev can only be called by the CreaticlesNFT contract. Used to pay winners after the CreaticlesNFT contract mints the winning NFTs
     * @param _to => the address that should receive the NFTs
     * @param _requestId => the requestId of the respective request
     * @param _proposalId => the list of proposalId
     * @param _tokenIds => the list of tokenIds
     * @param _tokenURLs => the list of tokenURLs
     * @param _winners => list of the addresses of the chosen winners
     * @param _tokenSupplies => supply of the NFTs
     */
    function acceptProposals(
        address _to,
        uint256 _requestId,
        uint256[] memory _proposalId,
        uint256[] memory _tokenIds,
        string[] memory _tokenURLs,
        address[] memory _winners,
        uint256 _tokenSupplies
    ) public isCreaticlesNFTContract {
        Request storage _request = requests[_requestId];
        require(
            _winners.length <= _request.numberOfWinners,
            "Requester cannot claim more winners than intially set"
        );
        uint256 _winnerValue = _request.value / _request.numberOfWinners;
        _request.value -= (_winnerValue * _winners.length);
        _request.active = false;

        address request_erc20_address = request_erc20_addresses[_requestId];

        //loop through winners and send their ETH
        for (uint256 i = 0; i < _winners.length; i++) {
            if (request_erc20_address == address(0)) {
                require(
                    payable(_winners[i]).send(_winnerValue),
                    "Failed to send Ether"
                );
            } else {
                // if we are not sending ether, we send ERC20 token
                IERC20(request_erc20_address).transfer(
                    _winners[i],
                    _winnerValue
                );
            }
        }

        // _request.active = false;
        emit ProposalAccepted(
            _to,
            _requestId,
            _proposalId,
            _tokenIds,
            _tokenURLs,
            _winners,
            _winnerValue,
            _tokenSupplies
        );
    }

    /**
     * @dev allows requester to reclaim their funds if they still have funds and the choosing period is over
     * @param _requestId => the requestId of the respective request
     */
    function reclaimFunds(uint256 _requestId)
        external
        onlyRequester(_requestId)
    {
        Request storage _request = requests[_requestId];
        // require(_msgSender() == _request.requester, "Sender is not Requester");
        require(
            block.timestamp >= _request.expiresAt + CHOOSING_PERIOD ||
                !_request.active,
            "Funds are not available"
        );

        address request_erc20_address = request_erc20_addresses[_requestId];

        if (request_erc20_address == address(0)) {
            payable(msg.sender).transfer(_request.value);
        } else {
            // here we send the ERC20 token back to the requester
            IERC20(request_erc20_address).transfer(msg.sender, _request.value);
        }

        emit FundsReclaimed(_requestId, _request.requester, _request.value);
        _request.value = 0;
    }

    /**
     * @dev set CHOOSING_PERIOD
     * @param _duration => (units of days)
     */
    function setChoosingPeriod(uint256 _duration) public isAdmin {
        CHOOSING_PERIOD = _duration * 1 days;
        emit ChoosingPeriodChanged(CHOOSING_PERIOD);
    }

    /**
     * @dev set COMMISSION
     * @param _commission =>  (parts per thousand)
     */
    function setCommission(uint256 _commission) public isAdmin {
        COMMISSION = _commission;
        emit CommissionChanged(COMMISSION);
    }

    //VIEW FUNCTIONS
    /**
     * @dev used by CreaticlesNFT contract to determine if the minter is the owner of the specified request
     * @param _addr => the target address
     * @param _requestId => the requestId of the respective request
     */
    function isRequester(address _addr, uint256 _requestId)
        public
        view
        returns (bool)
    {
        Request memory _request = requests[_requestId];
        require(_addr == _request.requester, "Address is not the requester");
        return true;
    }

    /**
     * @dev used by CreaticlesNFT contract to determine if the specified request is not closed
     * @param _requestId => the requestId of the respective request
     */
    function isOpenForChoosing(uint256 _requestId) public view returns (bool) {
        Request memory _request = requests[_requestId];
        require(
            block.timestamp >= ((_request.expiresAt * 1 seconds)),
            "Choosing period has not started"
        );
        require(
            block.timestamp <=
                ((_request.expiresAt * 1 seconds) + CHOOSING_PERIOD),
            "Choosing period is up"
        );
        require(_request.active, "request not active");
        return true;
    }

    /**
     * @dev used to set new admin
     * @param _newAdmin =>
     *
     */
    function setAdmin(address _newAdmin) external isCreaticlesNFTContract {
        adm = _newAdmin;
    }

    /**
     * @dev update TaxRecipient
     * @param _newRecipientDao => new DAO's address
     *
     */
    function updateTaxRecipient(address payable _newRecipientDao)
        public
        isAdmin
    {
        recipientDao = _newRecipientDao;
    }
}
