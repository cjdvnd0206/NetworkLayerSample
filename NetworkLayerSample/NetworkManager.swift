//
//  NetworkManager.swift
//  NetworkLayer
//
//  Created by 윤병진 on 2022/06/25.
//

import Foundation
import Alamofire

enum HTTPStatus: Int, Codable {
    // 필요할 경우 HTTP Status 사용
    case success = 200
    case badRequest = 400
    case unauthorized = 401
    case forbidden = 403
    case notFound = 404
    case internalServerError = 500
    case badGateway = 502
}

enum NetworkManager {
    // 사용할 API 이름을 넣는다
    case apiGet
    case apiPost(_ param1: String, _ param2: Int)
    case apiDelete
    case uploadImage(_ data: Data)
}
extension NetworkManager: DatetimeLogManager {
    // 네트워크 레이어
    private static let scheme = "https://"
#if DEBUG
    private static let domain = "" // 테스트 서버
    private static let port = ":8888"
#else
    private static let domain = "" // 운영서버
    private static let port = ":8888"
#endif
    private static let baseHost = scheme + domain + port
    
    // MARK: - ServerTrustManager(https SSL 인증)
    private var manager: ServerTrustManager {
        return ServerTrustManager(evaluators: [NetworkManager.domain: DisabledTrustEvaluator()])
    }
    
    private var requestModifier: Session.RequestModifier {
        // 응답시간 설정
        return { $0.timeoutInterval = 10.0 }
    }
    
    // MARK: - 인터넷 연결상태 확인(Alamofire Only)
    public static var isReachability: Bool {
        guard let manager = NetworkReachabilityManager() else { return false }
        
        return manager.isReachable
    }
    
    private var path: String {
        // 경로 설정
        switch self {
        case .apiGet:
            return NetworkManager.baseHost + "/apiGet"
        case .apiPost:
            return NetworkManager.baseHost + "/apiPost"
        case .apiDelete:
            return NetworkManager.baseHost + "/apiDelete"
        case .uploadImage:
            return NetworkManager.baseHost + "/uploadImage"
        }
    }
    
    private var method: HTTPMethod {
        // method 설정
        switch self {
        case .apiGet:
            return .get
        case .apiPost, .uploadImage:
            return .post
        case .apiDelete:
            return .delete
        }
    }
    
    private var parameters: [String: Any]? {
        // 파라미터 설정
        // Alamofire 사용할경우 Parameter Struct 사용 가능
        switch self {
        case .apiGet, .apiDelete, .uploadImage:
            return nil
        case .apiPost(let param1, let param2):
            return ["param1": param1,
                    "param2": param2]
        }
    }
    
    private var encoding: ParameterEncoding {
        // parameter 인코딩
        switch self {
        case .apiDelete:
            return URLEncoding.default
        case .apiPost, .uploadImage:
            return JSONEncoding.default
        case .apiGet:
            return URLEncoding.queryString
        }
    }
    
    private var headers: HTTPHeaders? {
        // 헤더 - 주로 토큰을 넣는다
        switch self {
        case .apiGet:
            return nil
        case .apiPost:
            return ["token": "post"]
        case .apiDelete:
            return ["token": "delete"]
        case .uploadImage:
            return ["token": "image"]
        }
    }
    
    private var uploadData: Data {
        // 이미지를 서버에 전송할 경우 사용
        if case .uploadImage(let image) = self {
            return image
        }
        
        return Data()
    }
    
    private var interceptor: RequestInterceptor? {
        // 토큰이 필요한 경우 만료 처리(Alamofire Only)
        switch self {
        case .apiGet:
            return nil
        case .apiPost, .apiDelete, .uploadImage:
            return TokenInterceptor()
        }
    }
    
    private var acceptableCode: Range<Int> {
        // Validation 적용(Alamofire Only)
        switch self {
        case .apiGet:
            return 200..<500
        case .apiPost, .apiDelete, .uploadImage:
            return 200..<400
        }
    }
    
    public func request<T: Decodable>(model: T.Type) async throws -> T {
        // 모델에 따른 요청(Alamofire Only, Swift Concurrency)
        let session = Session(interceptor: interceptor, serverTrustManager: manager)
        let dataTask = session.request(path, method: method, parameters: parameters, encoding: encoding, headers: headers, requestModifier: requestModifier)
            .validate(statusCode: acceptableCode)
            .serializingDecodable(model)
        let result = await dataTask.result
        if let response = await dataTask.response.response, let headers = response.headers["token"] {
            //토큰 저장하는 로직
            print(headers)
        }
        
        datetimeLog("\(dataTask)\n\(result)")
        
        guard let value = await dataTask.response.value else { throw NetworkLayerSampleError.connectionError() }
        
        return value
    }
    
    public func upload<T: Decodable>(model: T.Type) async throws -> T {
        // 이미지 업로드 요청(Alamofire Only, Swift Concurrency)
        let session = Session(interceptor: interceptor, serverTrustManager: manager)
        let dataTask = session.upload(multipartFormData: { multipartFormData in
            multipartFormData.append(uploadData, withName: "file", fileName: "houseMember.jpeg", mimeType: "image/jpeg")
            _ = parameters?.map { key, value in
                guard let data = "\(value)".data(using: .utf8) else { return }
                
                multipartFormData.append(data, withName: key)
            }
        }, to: path, headers: headers, requestModifier: requestModifier)
            .validate(statusCode: acceptableCode)
            .serializingDecodable(model)
        let result = await dataTask.result
        
        datetimeLog("\(dataTask)\n\(result)")
        
        guard let value = await dataTask.response.value else { throw NetworkLayerSampleError.connectionError() }
        
        return value
    }
    
    public func requestMockFrom<T: Decodable>(model: T.Type, _ filename: String) async throws -> T {
        // MockUP용 Request 함수
        guard let file = Bundle.main.url(forResource: filename, withExtension: nil) else { throw NetworkLayerSampleError.connectionError() }
        
        do {
            let data = try Data(contentsOf: file)
            let decoder = try JSONDecoder().decode(model, from: data)
            
            datetimeLog("\(decoder)")
            
            return decoder
        } catch {
            throw NetworkLayerSampleError.connectionError()
        }
    }
}

final class TokenInterceptor: RequestInterceptor {
    // 토큰 갱신 Interceptor (Alamofire Only)
    func adapt(_ urlRequest: URLRequest, for session: Session, completion: @escaping (Result<URLRequest, Error>) -> Void) {
        var urlRequest = urlRequest
        
        urlRequest.setValue("Refresh Token", forHTTPHeaderField: "token")
        completion(.success(urlRequest))
    }

    func retry(_ request: Request, for session: Session, dueTo error: Error, completion: @escaping (RetryResult) -> Void) {
        guard let response = request.task?.response as? HTTPURLResponse, (response.statusCode == 500 || response.statusCode == 403 || response.statusCode == 401) else {
            completion(.doNotRetryWithError(error))
            return
        }
        
        // 토큰 Refresh 처리
    }
}

protocol DatetimeLogManager {
    func datetimeLog(_ comment: String, _ function: String)
}
extension DatetimeLogManager {
    func datetimeLog(_ comment: String, _ function: String = #function) {
#if DEBUG
        let dateFormatter = DateFormatter()
        
        dateFormatter.dateFormat = "yyyy-MM-dd hh:mm:ss"
        print("\(dateFormatter.string(from: Date())) [\(function)] - \(comment)")
#endif
    }
}

enum NetworkLayerSampleError: Error {
    case connectionError(message: String = "서버와의 연결이 원활하지 않습니다")
    
    var description: String {
        switch self {
        case .connectionError(let message):
            return message
        }
    }
}
