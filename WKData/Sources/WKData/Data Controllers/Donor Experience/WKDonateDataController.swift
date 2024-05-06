import Foundation
import Contacts

@objc final public class WKDonateDataController: NSObject {
    
    // MARK: - Properties
    
    private let service = WKDataEnvironment.current.basicService
    private let sharedCacheStore = WKDataEnvironment.current.sharedCacheStore
    
    static var donateConfig: WKDonateConfig?
    static var paymentMethods: WKPaymentMethods?
    
    private let cacheDirectoryName = WKSharedCacheDirectoryNames.donorExperience.rawValue
    private let cacheDonateConfigContainerFileName = "AppsDonationConfig"
    private let cachePaymentMethodsResponseFileName = "PaymentMethods"
    
    // MARK: - Lifecycle
    
    public override init() {
        
    }
    
    // MARK: - Public
    
    public func loadConfigs() -> (donateConfig: WKDonateConfig?, paymentMethods: WKPaymentMethods?) {
        
        // First pull from memory
        guard Self.donateConfig == nil,
              Self.paymentMethods == nil else {
            return (Self.donateConfig, Self.paymentMethods)
        }
        
        // Fall back to persisted objects if within seven days
        let donateConfig: WKDonateConfig? = try? sharedCacheStore?.load(key: cacheDirectoryName, cacheDonateConfigContainerFileName)
        let paymentMethods: WKPaymentMethods? = try? sharedCacheStore?.load(key: cacheDirectoryName, cachePaymentMethodsResponseFileName)
        
        guard let donateConfigCachedDate = donateConfig?.cachedDate,
              let paymentMethodsCachedDate = paymentMethods?.cachedDate else {
            return (nil, nil)
        }
        
        let sevenDays = TimeInterval(60 * 60 * 24 * 7)
        guard (-donateConfigCachedDate.timeIntervalSinceNow) < sevenDays,
              (-paymentMethodsCachedDate.timeIntervalSinceNow) < sevenDays else {
            return (nil, nil)
        }
        
        Self.donateConfig = donateConfig
        Self.paymentMethods = paymentMethods
        
        return (Self.donateConfig, Self.paymentMethods)
    }
    
    @objc public func fetchConfigsForCountryCode(_ countryCode: String, completion: @escaping (Error?) -> Void) {
        fetchConfigs(for: countryCode) { result in
            switch result {
            case .success:
                completion(nil)
            case .failure(let error):
                completion(error)
            }
        }
    }
    
    public func fetchConfigs(for countryCode: String, completion: @escaping (Result<Void, Error>) -> Void) {
        
        guard let service else {
            completion(.failure(WKDataControllerError.basicServiceUnavailable))
            return
        }
        
        let group = DispatchGroup()
        
        guard let paymentMethodsURL = URL.paymentMethodsAPIURL(),
              let donateConfigURL = URL.donateConfigURL() else {
            completion(.failure(WKDataControllerError.failureCreatingRequestURL))
            return
        }
        
        let paymentMethodParameters: [String: Any] = [
            "action": "getPaymentMethods",
            "country": countryCode,
            "format": "json"
        ]
        
        let donateConfigParameters: [String: Any] = [
            "action": "raw"
        ]
        
        var errors: [Error] = []
        
        var donateConfig: WKDonateConfig?
        var paymentMethods: WKPaymentMethods?
        
        group.enter()
        let paymentMethodsRequest = WKBasicServiceRequest(url: paymentMethodsURL, method: .GET, parameters: paymentMethodParameters, acceptType: .json)
        service.performDecodableGET(request: paymentMethodsRequest) { (result: Result<WKPaymentMethods, Error>) in
            defer {
                group.leave()
            }
            
            switch result {
            case .success(let response):
                paymentMethods = response
            case .failure(let error):
                errors.append(error)
            }
        }
        
        group.enter()
        let donateConfigRequest = WKBasicServiceRequest(url: donateConfigURL, method: .GET, parameters: donateConfigParameters, acceptType: .json)
        service.performDecodableGET(request: donateConfigRequest) { (result: Result<WKDonateConfigResponse, Error>) in
            
            defer {
                group.leave()
            }
            
            switch result {
            case .success(let response):
                donateConfig = response.config
            case .failure(let error):
                errors.append(error)
            }
        }
        
        group.notify(queue: .main) {

            if let firstError = errors.first {
                Self.donateConfig = nil
                Self.paymentMethods = nil
                completion(.failure(firstError))
                return
            }
            
            guard var donateConfig,
                var paymentMethods else {
                Self.donateConfig = nil
                Self.paymentMethods = nil
                completion(.failure(WKServiceError.unexpectedResponse))
                return
            }
            
            donateConfig.cachedDate = Date()
            paymentMethods.cachedDate = Date()
            
            Self.donateConfig = donateConfig
            Self.paymentMethods = paymentMethods
            
            try? self.sharedCacheStore?.save(key: self.cacheDirectoryName, self.cacheDonateConfigContainerFileName, value: donateConfig)
            try? self.sharedCacheStore?.save(key: self.cacheDirectoryName, self.cachePaymentMethodsResponseFileName, value: paymentMethods)
            
            completion(.success(()))
        }
    }
    
    public func submitPayment(amount: Decimal, countryCode: String, currencyCode: String, languageCode: String, paymentToken: String, paymentNetwork: String?, donorNameComponents: PersonNameComponents, recurring: Bool, donorEmail: String, donorAddressComponents: CNPostalAddress, emailOptIn: Bool?, transactionFee: Bool, bannerID: String?, appVersion: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        
        guard let donatePaymentSubmissionURL = URL.donatePaymentSubmissionURL() else {
            completion(.failure(WKDataControllerError.failureCreatingRequestURL))
            return
        }
        
        var parameters: [String: String] = [
            "action": "submitPayment",
            "amount": (amount as NSNumber).stringValue,
            "currency": currencyCode,
            "recurring": recurring ? "1" : "0",
            "country": countryCode,
            "language": languageCode,
            "payment_token": paymentToken,
            "pay_the_fee": transactionFee ? "1" : "0",
            "full_name": donorNameComponents.formatted(.name(style: .long)),
            "email": donorEmail,
            "street_address": donorAddressComponents.street,
            "city": donorAddressComponents.city,
            "state_province": donorAddressComponents.state,
            "donor_country": donorAddressComponents.country,
            "postal_code": donorAddressComponents.postalCode,
            "payment_method": "applepay",
            "format": "json"
        ]
        
        if let emailOptIn {
            parameters["opt_in"] = emailOptIn ? "1" : "0"
        }
        
        if let firstName = donorNameComponents.givenName {
            parameters["first_name"] = firstName
        }
        
        if let lastName = donorNameComponents.familyName {
            parameters["last_name"] = lastName
        }
        
        if let paymentNetwork {
            parameters["payment_network"] = paymentNetwork
        }
        
        if let bannerID {
            parameters["banner"] = bannerID
        }
        
        if let appVersion {
            parameters["app_version"] = appVersion
        }
            
        let request = WKBasicServiceRequest(url: donatePaymentSubmissionURL, method: .POST, parameters: parameters, contentType: .form, acceptType: .json)
        service?.performDecodablePOST(request: request, completion: { (result: Result<WKPaymentSubmissionResponse, Error>) in
            switch result {
            case .success(let response):
                switch response.response.status.lowercased() {
                case "success":
                    completion(.success(()))
                case "error":
                    completion(.failure(WKDonateDataControllerError.paymentsWikiResponseError(reason: response.response.errorMessage, orderID: response.response.orderID)))
                default:
                    completion(.failure(WKServiceError.unexpectedResponse))
                }
                return
            case .failure(let error):
                completion(.failure(error))
            }
        })
    }
}
