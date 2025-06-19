// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract ApartmentRentalSystem is Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;
    
    Counters.Counter private _propertyIdCounter;
    
    enum PropertyStatus { Available, Rented, UnderMaintenance }
    enum DisputeStatus { None, Pending, Resolved }
    
    struct Property {
        uint256 propertyId;
        address landlord;
        string propertyAddress;
        string description;
        uint256 monthlyRent;
        uint256 securityDeposit;
        PropertyStatus status;
        uint256 minMaintenanceScore; // Minimum IoT score required (0-100)
        bool iotEnabled;
    }
    
    struct RentalAgreement {
        uint256 agreementId;
        uint256 propertyId;
        address tenant;
        address landlord;
        uint256 monthlyRent;
        uint256 securityDeposit;
        uint256 startDate;
        uint256 endDate;
        uint256 lastRentPayment;
        uint256 totalPaidRent;
        bool isActive;
        DisputeStatus disputeStatus;
    }
    
    struct MaintenanceRequest {
        uint256 requestId;
        uint256 propertyId;
        uint256 agreementId;
        address requester;
        string description;
        uint256 timestamp;
        bool resolved;
        uint256 cost;
    }
    
    struct IoTData {
        uint256 temperatureScore; // 0-100 (heating system)
        uint256 plumbingScore;    // 0-100 (water pressure, leaks)
        uint256 securityScore;    // 0-100 (locks, alarms)
        uint256 lastUpdate;
        uint256 overallScore;
    }
    
    mapping(uint256 => Property) public properties;
    mapping(uint256 => RentalAgreement) public rentalAgreements;
    mapping(uint256 => MaintenanceRequest[]) public maintenanceRequests;
    mapping(uint256 => IoTData) public iotData; // propertyId => IoTData
    mapping(uint256 => uint256) public rentEscrow; // agreementId => escrowed rent amount
    mapping(address => uint256[]) public landlordProperties;
    mapping(address => uint256[]) public tenantAgreements;
    
    uint256 public platformFeePercent = 3; // 3% platform fee
    uint256 public disputeDeposit = 0.01 ether; // Deposit required to raise dispute
    
    event PropertyListed(uint256 indexed propertyId, address indexed landlord, uint256 monthlyRent);
    event RentalAgreementCreated(uint256 indexed agreementId, uint256 indexed propertyId, address indexed tenant);
    event RentPaid(uint256 indexed agreementId, uint256 amount, uint256 month);
    event RentReleased(uint256 indexed agreementId, address indexed landlord, uint256 amount);
    event MaintenanceRequested(uint256 indexed propertyId, uint256 indexed requestId, address requester);
    event MaintenanceCompleted(uint256 indexed propertyId, uint256 indexed requestId);
    event IoTDataUpdated(uint256 indexed propertyId, uint256 overallScore);
    event DisputeRaised(uint256 indexed agreementId, address indexed initiator);
    
    constructor() Ownable(msg.sender) {}
    
    // Core Function 1: List Property for Rent
    function listProperty(
        string memory _propertyAddress,
        string memory _description,
        uint256 _monthlyRent,
        uint256 _securityDeposit,
        uint256 _minMaintenanceScore,
        bool _iotEnabled
    ) external returns (uint256) {
        require(_monthlyRent > 0, "Monthly rent must be greater than 0");
        require(_securityDeposit > 0, "Security deposit must be greater than 0");
        require(_minMaintenanceScore <= 100, "Maintenance score must be 0-100");
        
        _propertyIdCounter.increment();
        uint256 propertyId = _propertyIdCounter.current();
        
        properties[propertyId] = Property({
            propertyId: propertyId,
            landlord: msg.sender,
            propertyAddress: _propertyAddress,
            description: _description,
            monthlyRent: _monthlyRent,
            securityDeposit: _securityDeposit,
            status: PropertyStatus.Available,
            minMaintenanceScore: _minMaintenanceScore,
            iotEnabled: _iotEnabled
        });
        
        landlordProperties[msg.sender].push(propertyId);
        
        emit PropertyListed(propertyId, msg.sender, _monthlyRent);
        return propertyId;
    }
    
    // Core Function 2: Create Rental Agreement and Pay First Month + Deposit
    function createRentalAgreement(
        uint256 _propertyId,
        uint256 _startDate,
        uint256 _endDate
    ) external payable nonReentrant {
        Property storage property = properties[_propertyId];
        require(property.status == PropertyStatus.Available, "Property is not available");
        require(_startDate >= block.timestamp, "Start date must be in the future");
        require(_endDate > _startDate, "End date must be after start date");
        require(msg.sender != property.landlord, "Landlord cannot rent their own property");
        
        uint256 totalRequired = property.monthlyRent + property.securityDeposit;
        require(msg.value >= totalRequired, "Insufficient payment for first month rent and deposit");
        
        // Check IoT maintenance score if enabled
        if (property.iotEnabled) {
            require(iotData[_propertyId].overallScore >= property.minMaintenanceScore, 
                   "Property maintenance score below minimum requirement");
        }
        
        uint256 agreementId = _propertyIdCounter.current() + 1000; // Offset for agreement IDs
        
        rentalAgreements[agreementId] = RentalAgreement({
            agreementId: agreementId,
            propertyId: _propertyId,
            tenant: msg.sender,
            landlord: property.landlord,
            monthlyRent: property.monthlyRent,
            securityDeposit: property.securityDeposit,
            startDate: _startDate,
            endDate: _endDate,
            lastRentPayment: _startDate,
            totalPaidRent: property.monthlyRent,
            isActive: true,
            disputeStatus: DisputeStatus.None
        });
        
        // Update property status
        property.status = PropertyStatus.Rented;
        
        // Store rent in escrow (will be released based on maintenance compliance)
        rentEscrow[agreementId] = property.monthlyRent;
        
        // Track tenant agreements
        tenantAgreements[msg.sender].push(agreementId);
        
        // Refund excess payment
        if (msg.value > totalRequired) {
            payable(msg.sender).transfer(msg.value - totalRequired);
        }
        
        emit RentalAgreementCreated(agreementId, _propertyId, msg.sender);
        emit RentPaid(agreementId, property.monthlyRent, _startDate);
    }
    
    // Core Function 3: Pay Monthly Rent
    function payMonthlyRent(uint256 _agreementId) external payable nonReentrant {
        RentalAgreement storage agreement = rentalAgreements[_agreementId];
        require(agreement.isActive, "Rental agreement is not active");
        require(msg.sender == agreement.tenant, "Only tenant can pay rent");
        require(block.timestamp <= agreement.endDate, "Rental agreement has expired");
        require(msg.value >= agreement.monthlyRent, "Insufficient rent payment");
        
        // Check if rent is due (30 days since last payment)
        require(block.timestamp >= agreement.lastRentPayment + 30 days, "Rent not yet due");
        
        // Update rental agreement
        agreement.lastRentPayment = block.timestamp;
        agreement.totalPaidRent += agreement.monthlyRent;
        
        // Add to escrow
        rentEscrow[_agreementId] += agreement.monthlyRent;
        
        // Refund excess payment
        if (msg.value > agreement.monthlyRent) {
            payable(msg.sender).transfer(msg.value - agreement.monthlyRent);
        }
        
        emit RentPaid(_agreementId, agreement.monthlyRent, block.timestamp);
    }
    
    // Additional Functions for Maintenance and IoT Integration
    
    function releaseMonthlRent(uint256 _agreementId) external nonReentrant {
        RentalAgreement storage agreement = rentalAgreements[_agreementId];
        Property storage property = properties[agreement.propertyId];
        
        require(agreement.isActive, "Agreement is not active");
        require(rentEscrow[_agreementId] > 0, "No rent to release");
        
        // Check maintenance compliance if IoT enabled
        if (property.iotEnabled) {
            require(iotData[agreement.propertyId].overallScore >= property.minMaintenanceScore,
                   "Maintenance score below minimum - rent held in escrow");
            require(block.timestamp <= iotData[agreement.propertyId].lastUpdate + 7 days,
                   "IoT data is outdated - please update sensors");
        }
        
        uint256 rentAmount = rentEscrow[_agreementId];
        uint256 platformFee = (rentAmount * platformFeePercent) / 100;
        uint256 landlordPayment = rentAmount - platformFee;
        
        // Reset escrow
        rentEscrow[_agreementId] = 0;
        
        // Transfer payments
        payable(agreement.landlord).transfer(landlordPayment);
        
        emit RentReleased(_agreementId, agreement.landlord, landlordPayment);
    }
    
    function updateIoTData(
        uint256 _propertyId,
        uint256 _temperatureScore,
        uint256 _plumbingScore,
        uint256 _securityScore
    ) external {
        Property storage property = properties[_propertyId];
        require(msg.sender == property.landlord || msg.sender == owner(), "Unauthorized IoT update");
        require(_temperatureScore <= 100 && _plumbingScore <= 100 && _securityScore <= 100, 
               "Scores must be 0-100");
        
        uint256 overallScore = (_temperatureScore + _plumbingScore + _securityScore) / 3;
        
        iotData[_propertyId] = IoTData({
            temperatureScore: _temperatureScore,
            plumbingScore: _plumbingScore,
            securityScore: _securityScore,
            lastUpdate: block.timestamp,
            overallScore: overallScore
        });
        
        emit IoTDataUpdated(_propertyId, overallScore);
    }
    
    function requestMaintenance(
        uint256 _propertyId,
        uint256 _agreementId,
        string memory _description
    ) external returns (uint256) {
        RentalAgreement storage agreement = rentalAgreements[_agreementId];
        require(agreement.isActive, "Agreement is not active");
        require(msg.sender == agreement.tenant || msg.sender == agreement.landlord, 
               "Only tenant or landlord can request maintenance");
        
        uint256 requestId = maintenanceRequests[_propertyId].length;
        
        maintenanceRequests[_propertyId].push(MaintenanceRequest({
            requestId: requestId,
            propertyId: _propertyId,
            agreementId: _agreementId,
            requester: msg.sender,
            description: _description,
            timestamp: block.timestamp,
            resolved: false,
            cost: 0
        }));
        
        emit MaintenanceRequested(_propertyId, requestId, msg.sender);
        return requestId;
    }
    
    function completeMaintenance(
        uint256 _propertyId,
        uint256 _requestId,
        uint256 _cost
    ) external {
        Property storage property = properties[_propertyId];
        require(msg.sender == property.landlord, "Only landlord can complete maintenance");
        require(_requestId < maintenanceRequests[_propertyId].length, "Invalid request ID");
        
        MaintenanceRequest storage request = maintenanceRequests[_propertyId][_requestId];
        require(!request.resolved, "Maintenance already completed");
        
        request.resolved = true;
        request.cost = _cost;
        
        emit MaintenanceCompleted(_propertyId, _requestId);
    }
    
    function raiseDispute(uint256 _agreementId) external payable {
        require(msg.value >= disputeDeposit, "Insufficient dispute deposit");
        
        RentalAgreement storage agreement = rentalAgreements[_agreementId];
        require(agreement.isActive, "Agreement is not active");
        require(msg.sender == agreement.tenant || msg.sender == agreement.landlord, 
               "Only parties to agreement can raise dispute");
        require(agreement.disputeStatus == DisputeStatus.None, "Dispute already exists");
        
        agreement.disputeStatus = DisputeStatus.Pending;
        
        emit DisputeRaised(_agreementId, msg.sender);
    }
    
    function terminateAgreement(uint256 _agreementId) external nonReentrant {
        RentalAgreement storage agreement = rentalAgreements[_agreementId];
        Property storage property = properties[agreement.propertyId];
        
        require(agreement.isActive, "Agreement already terminated");
        require(msg.sender == agreement.tenant || msg.sender == agreement.landlord || 
               block.timestamp > agreement.endDate, "Unauthorized termination");
        
        agreement.isActive = false;
        property.status = PropertyStatus.Available;
        
        // Return security deposit to tenant (minus any deductions)
        if (agreement.disputeStatus == DisputeStatus.None) {
            payable(agreement.tenant).transfer(agreement.securityDeposit);
        }
        
        // Release any remaining escrowed rent
        if (rentEscrow[_agreementId] > 0) {
            uint256 remainingRent = rentEscrow[_agreementId];
            rentEscrow[_agreementId] = 0;
            payable(agreement.landlord).transfer(remainingRent);
        }
    }
    
    // View Functions
    function getPropertyDetails(uint256 _propertyId) external view returns (Property memory) {
        return properties[_propertyId];
    }
    
    function getRentalAgreement(uint256 _agreementId) external view returns (RentalAgreement memory) {
        return rentalAgreements[_agreementId];
    }
    
    function getIoTData(uint256 _propertyId) external view returns (IoTData memory) {
        return iotData[_propertyId];
    }
    
    function getMaintenanceRequests(uint256 _propertyId) external view returns (MaintenanceRequest[] memory) {
        return maintenanceRequests[_propertyId];
    }
    
    function getLandlordProperties(address _landlord) external view returns (uint256[] memory) {
        return landlordProperties[_landlord];
    }
    
    function getTenantAgreements(address _tenant) external view returns (uint256[] memory) {
        return tenantAgreements[_tenant];
    }
    
    function getEscrowBalance(uint256 _agreementId) external view returns (uint256) {
        return rentEscrow[_agreementId];
    }
    
    // Admin Functions
    function setPlatformFee(uint256 _feePercent) external onlyOwner {
        require(_feePercent <= 10, "Platform fee cannot exceed 10%");
        platformFeePercent = _feePercent;
    }
    
    function setDisputeDeposit(uint256 _deposit) external onlyOwner {
        disputeDeposit = _deposit;
    }
    
    function withdrawPlatformFees() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
    
    function resolveDispute(uint256 _agreementId, bool _favorTenant) external onlyOwner {
        RentalAgreement storage agreement = rentalAgreements[_agreementId];
        require(agreement.disputeStatus == DisputeStatus.Pending, "No pending dispute");
        
        agreement.disputeStatus = DisputeStatus.Resolved;
        
        // Distribute security deposit based on resolution
        if (_favorTenant) {
            payable(agreement.tenant).transfer(agreement.securityDeposit);
        } else {
            payable(agreement.landlord).transfer(agreement.securityDeposit);
        }
    }
}
