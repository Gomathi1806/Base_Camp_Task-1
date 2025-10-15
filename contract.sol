/ SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title VideoPaywall
 * @dev Decentralized video platform with micropayments
 * Creators upload videos to IPFS and set viewing prices
 * Platform takes 6% fee, creator gets 94%
 */
contract VideoPaywall {
    // Platform fee: 6% (600 basis points out of 10000)
    uint256 public constant PLATFORM_FEE_BPS = 600;
    uint256 public constant BPS_DENOMINATOR = 10000;
    
    address public platformOwner;
    uint256 public totalVideos;
    
    struct Video {
        uint256 id;
        address creator;
        string ipfsHash;
        uint256 price;
        uint256 totalEarnings;
        uint256 viewCount;
        uint256 timestamp;
        bool isActive;
    }
    
    // videoId => Video
    mapping(uint256 => Video) public videos;
    
    // videoId => viewer => hasPaid
    mapping(uint256 => mapping(address => bool)) public hasAccess;
    
    // creator => videoIds[]
    mapping(address => uint256[]) public creatorVideos;
    
    // Events
    event VideoUploaded(
        uint256 indexed videoId,
        address indexed creator,
        string ipfsHash,
        uint256 price,
        uint256 timestamp
    );
    
    event VideoUnlocked(
        uint256 indexed videoId,
        address indexed viewer,
        address indexed creator,
        uint256 price,
        uint256 platformFee,
        uint256 creatorEarning
    );
    
    event VideoDeactivated(uint256 indexed videoId, address indexed creator);
    
    event PlatformFeeWithdrawn(address indexed owner, uint256 amount);
    
    modifier onlyPlatformOwner() {
        require(msg.sender == platformOwner, "Not platform owner");
        _;
    }
    
    modifier onlyCreator(uint256 _videoId) {
        require(videos[_videoId].creator == msg.sender, "Not video creator");
        _;
    }
    
    constructor() {
        platformOwner = msg.sender;
    }
    
    /**
     * @dev Upload a new video
     * @param _ipfsHash IPFS hash of the video
     * @param _price Price to unlock video in wei
     */
    function uploadVideo(string memory _ipfsHash, uint256 _price) external returns (uint256) {
        require(bytes(_ipfsHash).length > 0, "Invalid IPFS hash");
        require(_price > 0, "Price must be greater than 0");
        
        totalVideos++;
        uint256 videoId = totalVideos;
        
        videos[videoId] = Video({
            id: videoId,
            creator: msg.sender,
            ipfsHash: _ipfsHash,
            price: _price,
            totalEarnings: 0,
            viewCount: 0,
            timestamp: block.timestamp,
            isActive: true
        });
        
        creatorVideos[msg.sender].push(videoId);
        
        emit VideoUploaded(videoId, msg.sender, _ipfsHash, _price, block.timestamp);
        
        return videoId;
    }
    
    /**
     * @dev Pay to unlock a video
     * @param _videoId ID of the video to unlock
     */
    function unlockVideo(uint256 _videoId) external payable {
        Video storage video = videos[_videoId];
        
        require(video.isActive, "Video not active");
        require(msg.value >= video.price, "Insufficient payment");
        require(!hasAccess[_videoId][msg.sender], "Already unlocked");
        require(msg.sender != video.creator, "Creator has automatic access");
        
        // Calculate fees
        uint256 platformFee = (msg.value * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 creatorEarning = msg.value - platformFee;
        
        // Grant access
        hasAccess[_videoId][msg.sender] = true;
        
        // Update stats
        video.totalEarnings += creatorEarning;
        video.viewCount++;
        
        // Transfer funds to creator
        (bool success, ) = payable(video.creator).call{value: creatorEarning}("");
        require(success, "Transfer to creator failed");
        
        // Platform fee stays in contract
        
        emit VideoUnlocked(_videoId, msg.sender, video.creator, msg.value, platformFee, creatorEarning);
        
        // Refund excess payment
        if (msg.value > video.price) {
            (bool refundSuccess, ) = payable(msg.sender).call{value: msg.value - video.price}("");
            require(refundSuccess, "Refund failed");
        }
    }
    
    /**
     * @dev Check if viewer has access to video
     * @param _videoId ID of the video
     * @param _viewer Address of the viewer
     */
    function checkAccess(uint256 _videoId, address _viewer) external view returns (bool) {
        // Creator always has access
        if (videos[_videoId].creator == _viewer) {
            return true;
        }
        return hasAccess[_videoId][_viewer];
    }
    
    /**
     * @dev Get video details (returns IPFS hash only if caller has access)
     * @param _videoId ID of the video
     */
    function getVideo(uint256 _videoId) external view returns (
        uint256 id,
        address creator,
        string memory ipfsHash,
        uint256 price,
        uint256 totalEarnings,
        uint256 viewCount,
        uint256 timestamp,
        bool isActive,
        bool hasViewerAccess
    ) {
        Video memory video = videos[_videoId];
        bool access = video.creator == msg.sender || hasAccess[_videoId][msg.sender];
        
        return (
            video.id,
            video.creator,
            access ? video.ipfsHash : "", // Only return IPFS hash if has access
            video.price,
            video.totalEarnings,
            video.viewCount,
            video.timestamp,
            video.isActive,
            access
        );
    }
    
    /**
     * @dev Get all videos (paginated)
     * @param _offset Starting index
     * @param _limit Number of videos to return
     */
    function getVideos(uint256 _offset, uint256 _limit) external view returns (
        uint256[] memory ids,
        address[] memory creators,
        uint256[] memory prices,
        uint256[] memory viewCounts,
        uint256[] memory timestamps,
        bool[] memory activeStatus
    ) {
        uint256 end = _offset + _limit;
        if (end > totalVideos) {
            end = totalVideos;
        }
        
        uint256 length = end - _offset;
        ids = new uint256[](length);
        creators = new address[](length);
        prices = new uint256[](length);
        viewCounts = new uint256[](length);
        timestamps = new uint256[](length);
        activeStatus = new bool[](length);
        
        for (uint256 i = 0; i < length; i++) {
            uint256 videoId = _offset + i + 1;
            Video memory video = videos[videoId];
            ids[i] = video.id;
            creators[i] = video.creator;
            prices[i] = video.price;
            viewCounts[i] = video.viewCount;
            timestamps[i] = video.timestamp;
            activeStatus[i] = video.isActive;
        }
        
        return (ids, creators, prices, viewCounts, timestamps, activeStatus);
    }
    
    /**
     * @dev Get videos by creator
     * @param _creator Address of the creator
     */
    function getCreatorVideos(address _creator) external view returns (uint256[] memory) {
        return creatorVideos[_creator];
    }
    
    /**
     * @dev Deactivate a video (creator only)
     * @param _videoId ID of the video
     */
    function deactivateVideo(uint256 _videoId) external onlyCreator(_videoId) {
        videos[_videoId].isActive = false;
        emit VideoDeactivated(_videoId, msg.sender);
    }
    
    /**
     * @dev Withdraw platform fees (owner only)
     */
    function withdrawPlatformFees() external onlyPlatformOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No fees to withdraw");
        
        (bool success, ) = payable(platformOwner).call{value: balance}("");
        require(success, "Withdrawal failed");
        
        emit PlatformFeeWithdrawn(platformOwner, balance);
    }
    
    /**
     * @dev Get contract balance (platform fees accumulated)
     */
    function getPlatformBalance() external view returns (uint256) {
        return address(this).balance;
    }
}

