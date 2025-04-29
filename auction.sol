
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DigitalAuctionHouse
 * @dev A contract for managing auctions of digital goods (NFTs)
 */
contract DigitalAuctionHouse is ReentrancyGuard, Ownable {
    // Auction structure
    struct Auction {
        address seller;
        address tokenContract;
        uint256 tokenId;
        uint256 startingPrice;
        uint256 reservePrice;  // Minimum price that must be met
        uint256 endTime;
        address highestBidder;
        uint256 highestBid;
        bool ended;
        bool settled;
    }

    // Mapping from auction ID to Auction
    mapping(uint256 => Auction) public auctions;
    
    // Counter for auction IDs
    uint256 public auctionCounter;
    
    // Platform fee percentage (in basis points: 250 = 2.5%)
    uint256 public platformFee = 250;
    
    // Events
    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        address indexed tokenContract,
        uint256 tokenId,
        uint256 startingPrice,
        uint256 reservePrice,
        uint256 endTime
    );
    
    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 amount
    );
    
    event AuctionSettled(
        uint256 indexed auctionId,
        address indexed winner,
        uint256 amount
    );
    
    event AuctionCancelled(uint256 indexed auctionId);
    
    /**
     * @dev Constructor sets the owner of the auction house
     */
    constructor() Ownable(msg.sender) {}
    
    /**
     * @notice Creates a new auction for a digital good (NFT)
     * @param _tokenContract Address of the NFT contract
     * @param _tokenId Token ID of the NFT
     * @param _startingPrice Starting price for the auction
     * @param _reservePrice Minimum price that must be met for the auction to be successful
     * @param _duration Duration of the auction in seconds
     */
    function createAuction(
        address _tokenContract,
        uint256 _tokenId,
        uint256 _startingPrice,
        uint256 _reservePrice,
        uint256 _duration
    ) external nonReentrant {
        require(_tokenContract != address(0), "Invalid token contract");
        require(_startingPrice > 0, "Starting price must be greater than zero");
        require(_reservePrice >= _startingPrice, "Reserve price must be at least starting price");
        require(_duration >= 1 hours, "Auction must be at least 1 hour");
        require(_duration <= 30 days, "Auction cannot exceed 30 days");
        
        // Get the NFT from the seller and hold it in escrow
        IERC721 nftContract = IERC721(_tokenContract);
        require(nftContract.ownerOf(_tokenId) == msg.sender, "Caller does not own the NFT");
        
        // Transfer NFT to this contract
        nftContract.transferFrom(msg.sender, address(this), _tokenId);
        
        // Create new auction
        uint256 auctionId = auctionCounter;
        auctions[auctionId] = Auction({
            seller: msg.sender,
            tokenContract: _tokenContract,
            tokenId: _tokenId,
            startingPrice: _startingPrice,
            reservePrice: _reservePrice,
            endTime: block.timestamp + _duration,
            highestBidder: address(0),
            highestBid: 0,
            ended: false,
            settled: false
        });
        
        // Increment auction counter
        auctionCounter++;
        
        emit AuctionCreated(
            auctionId,
            msg.sender,
            _tokenContract,
            _tokenId,
            _startingPrice,
            _reservePrice,
            block.timestamp + _duration
        );
    }
    
    /**
     * @notice Places a bid on an active auction
     * @param _auctionId ID of the auction
     */
    function placeBid(uint256 _auctionId) external payable nonReentrant {
        Auction storage auction = auctions[_auctionId];
        
        require(!auction.ended, "Auction has ended");
        require(block.timestamp < auction.endTime, "Auction has expired");
        require(msg.sender != auction.seller, "Seller cannot bid on their own auction");
        
        uint256 minBidAmount;
        
        if (auction.highestBid == 0) {
            // First bid must be at least the starting price
            minBidAmount = auction.startingPrice;
        } else {
            // Subsequent bids must be at least 5% higher than the current highest bid
            minBidAmount = auction.highestBid * 105 / 100;
        }
        
        require(msg.value >= minBidAmount, "Bid amount is too low");
        
        // Return funds to the previous highest bidder if there is one
        if (auction.highestBidder != address(0)) {
            (bool success, ) = auction.highestBidder.call{value: auction.highestBid}("");
            require(success, "Failed to return funds to previous highest bidder");
        }
        
        // Update auction with new highest bid
        auction.highestBidder = msg.sender;
        auction.highestBid = msg.value;
        
        emit BidPlaced(_auctionId, msg.sender, msg.value);
    }
    
    /**
     * @notice Settles an auction after it has ended
     * @param _auctionId ID of the auction to settle
     */
    function settleAuction(uint256 _auctionId) external nonReentrant {
        Auction storage auction = auctions[_auctionId];
        
        require(!auction.settled, "Auction has already been settled");
        require(block.timestamp >= auction.endTime || auction.ended, "Auction has not ended yet");
        
        auction.ended = true;
        auction.settled = true;
        
        // Check if there was a winning bid that met the reserve price
        if (auction.highestBidder != address(0) && auction.highestBid >= auction.reservePrice) {
            // Calculate platform fee
            uint256 fee = (auction.highestBid * platformFee) / 10000;
            uint256 sellerAmount = auction.highestBid - fee;
            
            // Transfer NFT to the highest bidder
            IERC721(auction.tokenContract).transferFrom(address(this), auction.highestBidder, auction.tokenId);
            
            // Transfer funds to the seller
            (bool success, ) = auction.seller.call{value: sellerAmount}("");
            require(success, "Failed to send funds to seller");
            
            emit AuctionSettled(_auctionId, auction.highestBidder, auction.highestBid);
        } else {
            // Return NFT to the seller if reserve price was not met or no bids
            IERC721(auction.tokenContract).transferFrom(address(this), auction.seller, auction.tokenId);
            
            // Return funds to the highest bidder if there was one
            if (auction.highestBidder != address(0)) {
                (bool success, ) = auction.highestBidder.call{value: auction.highestBid}("");
                require(success, "Failed to return funds to highest bidder");
            }
            
            emit AuctionCancelled(_auctionId);
        }
    }
    
    /**
     * @notice Allows the owner to update the platform fee
     * @param _newPlatformFee New platform fee in basis points (e.g., 250 = 2.5%)
     */
    function setPlatformFee(uint256 _newPlatformFee) external onlyOwner {
        require(_newPlatformFee <= 1000, "Fee cannot exceed 10%");
        platformFee = _newPlatformFee;
    }
}
