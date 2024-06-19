import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Polyline
import Turf

typealias JSONDictionary = [String: Any]

/// Indicates that an error occurred in MapboxDirections.
public let MBDirectionsErrorDomain = "com.mapbox.directions.ErrorDomain"


/**
 A `Directions` object provides you with optimal directions between different locations, or waypoints. The directions object passes your request to the [Mapbox Directions API](https://docs.mapbox.com/api/navigation/#directions) and returns the requested information to a closure (block) that you provide. A directions object can handle multiple simultaneous requests. A `RouteOptions` object specifies criteria for the results, such as intermediate waypoints, a mode of transportation, or the level of detail to be returned.
 
 Each result produced by the directions object is stored in a `Route` object. Depending on the `RouteOptions` object you provide, each route may include detailed information suitable for turn-by-turn directions, or it may include only high-level information such as the distance, estimated travel time, and name of each leg of the trip. The waypoints that form the request may be conflated with nearby locations, as appropriate; the resulting waypoints are provided to the closure.
 */
open class Directions: NSObject {
    
    /**
     A tuple type representing the direction session that was generated from the request.
     
     - parameter options: A `DirectionsOptions ` object representing the request parameter options.
     
     - parameter credentials: A object containing the credentials used to make the request.
     */
    public typealias Session = (options: DirectionsOptions, credentials: Credentials)
    
    /**
     A closure (block) to be called when a directions request is complete.
     
     - parameter session: A `Directions.Session` object containing session information
     
     - parameter result: A `Result` enum that represents the `RouteResponse` if the request returned successfully, or the error if it did not.
     */
    public typealias RouteCompletionHandler = (_ session: Session, _ result: Result<RouteResponse, DirectionsError>) -> Void
    
    public typealias CustomRouteCompletionHandler = (_ session: Session, _ result: Result<[LocationCoordinate2D], DirectionsError>) -> Void
    
    /**
     A closure (block) to be called when a map matching request is complete.
     
     - parameter session: A `Directions.Session` object containing session information
     
     - parameter result: A `Result` enum that represents the `MapMatchingResponse` if the request returned successfully, or the error if it did not.
     */
    public typealias MatchCompletionHandler = (_ session: Session, _ result: Result<MapMatchingResponse, DirectionsError>) -> Void
    
    /**
     A closure (block) to be called when a directions refresh request is complete.
     
     - parameter credentials: An object containing the credentials used to make the request.
     - parameter result: A `Result` enum that represents the `RouteRefreshResponse` if the request returned successfully, or the error if it did not.
     
     - postcondition: To update the original route, pass `RouteRefreshResponse.route` into the `Route.refreshLegAttributes(from:)`, `Route.refreshLegIncidents(from:)`, `Route.refreshLegClosures(from:legIndex:legShapeIndex:)` or `Route.refresh(from:refreshParameters:)` methods.
     */
    public typealias RouteRefreshCompletionHandler = (_ credentials: Credentials, _ result: Result<RouteRefreshResponse, DirectionsError>) -> Void
    
    // MARK: Creating a Directions Object
    
    /**
     The shared directions object.
     
     To use this object, a Mapbox [access token](https://docs.mapbox.com/help/glossary/access-token/) should be specified in the `MBXAccessToken` key in the main application bundle’s Info.plist.
     */
    public static let shared = Directions()

    /**
     The Authorization & Authentication credentials that are used for this service.
     
     If nothing is provided, the default behavior is to read credential values from the developer's Info.plist.
     */
    public let credentials: Credentials
    
    private var authenticationParams: [URLQueryItem] {
        var params: [URLQueryItem] = [
            URLQueryItem(name: "access_token", value: credentials.accessToken)
        ]

        if let skuToken = credentials.skuToken {
            params.append(URLQueryItem(name: "sku", value: skuToken))
        }
        return params
    }

    private let urlSession: URLSession
    private let processingQueue: DispatchQueue

    /**
     Creates a new instance of Directions object.
     - Parameters:
       - credentials: Credentials that will be used to make API requests to Mapbox Directions API.
       - urlSession: URLSession that will be used to submit API requests to Mapbox Directions API.
       - processingQueue: A DispatchQueue that will be used for CPU intensive work.
     */
    public init(credentials: Credentials = .init(),
                urlSession: URLSession = .shared,
                processingQueue: DispatchQueue = .global(qos: .userInitiated)) {
        self.credentials = credentials
        self.urlSession = urlSession
        self.processingQueue = processingQueue
    }
    
    
    // MARK: Getting Directions
    
    /**
     Begins asynchronously calculating routes using the given options and delivers the results to a closure.
     
     This method retrieves the routes asynchronously from the [Mapbox Directions API](https://www.mapbox.com/api-documentation/navigation/#directions) over a network connection. If a connection error or server error occurs, details about the error are passed into the given completion handler in lieu of the routes.
     
     Routes may be displayed atop a [Mapbox map](https://www.mapbox.com/maps/).
     
     - parameter options: A `RouteOptions` object specifying the requirements for the resulting routes.
     - parameter completionHandler: The closure (block) to call with the resulting routes. This closure is executed on the application’s main thread.
     - returns: The data task used to perform the HTTP request. If, while waiting for the completion handler to execute, you no longer want the resulting routes, cancel this task.
     */
    @discardableResult open func calculatewtf(_ options: RouteOptions, completionHandler: @escaping RouteCompletionHandler) -> URLSessionDataTask {
        options.fetchStartDate = Date()
        let session = (options: options as DirectionsOptions, credentials: self.credentials)
        let request = urlRequest(forCalculating: options)
        let requestTask = urlSession.dataTask(with: request) { (possibleData, possibleResponse, possibleError) in
            
            if let urlError = possibleError as? URLError {
                DispatchQueue.main.async {
                    completionHandler(session, .failure(.network(urlError)))
                }
                return
            }
            
            guard let response = possibleResponse, ["application/json", "text/html"].contains(response.mimeType) else {
                DispatchQueue.main.async {
                    completionHandler(session, .failure(.invalidResponse(possibleResponse)))
                }
                return
            }
            
            guard let data = possibleData else {
                DispatchQueue.main.async {
                    completionHandler(session, .failure(.noData))
                }
                return
            }
            
            self.processingQueue.async {
                do {
                    let decoder = JSONDecoder()
                    decoder.userInfo = [.options: options,
                                        .credentials: self.credentials]
                    
                    guard let disposition = try? decoder.decode(ResponseDisposition.self, from: data) else {
                        let apiError = DirectionsError(code: nil, message: nil, response: possibleResponse, underlyingError: possibleError)

                        DispatchQueue.main.async {
                            completionHandler(session, .failure(apiError))
                        }
                        return
                    }
                    
                    guard (disposition.code == nil && disposition.message == nil) || disposition.code == "Ok" else {
                        let apiError = DirectionsError(code: disposition.code, message: disposition.message, response: response, underlyingError: possibleError)
                        DispatchQueue.main.async {
                            completionHandler(session, .failure(apiError))
                        }
                        return
                    }
                    
                    let result = try decoder.decode(RouteResponse.self, from: data)
                    guard result.routes != nil else {
                        DispatchQueue.main.async {
                            completionHandler(session, .failure(.unableToRoute))
                        }
                        return
                    }
                    
                    DispatchQueue.main.async {
                        
                        
//                    transportType: .automobile, // Assuming mode of transport; modify as needed
//                    maneuverLocation: maneuverLocation,
//                    maneuverType: .turn, // You may need a function to map from sign to ManeuverType
//                    maneuverDirection: maneuverDirection,
//                    instructions: instruction.text,
////                            instructionsDisplayedAlongStep: [visual],
////                            instructionsSpokenAlongStep: [audio],
//                    drivingSide: .left, // Assume 'right'; adjust based on actual data or settings
//                    distance: instruction.distance,
//                    expectedTravelTime: TimeInterval(instruction.time / 1000)
                        //foreignMembers
                        //maneuverForeignMembers
                        
                        
                        
                        
//                        for var step in result.routes![0].legs[0].steps {
//                            
//                            
////                            var yuy = MapboxDirections.Intersection(location: step.maneuverLocation, headings: [0], approachIndex: 0, outletIndex: 0, outletIndexes: IndexSet(integer: 0), approachLanes: nil, usableApproachLanes: nil, preferredApproachLanes: nil, usableLaneIndication: nil)
////                            
////                            var yuy2 = MapboxDirections.Intersection(location: step.maneuverLocation, headings: [0], approachIndex: 0, outletIndex: 0, outletIndexes: IndexSet(integer: 0), approachLanes: nil, usableApproachLanes: nil, preferredApproachLanes: nil, usableLaneIndication: nil)
//                            
////                            result.routes![0].legs[0]
////                            step.intersections = [yuy, yuy2]
////
//////                            step.intersections = [step.intersections![0]]
////                            
//                            print("break:")
//                            print("intersections count:" + String(step.intersections!.count))
//                            var newIntersections: [Intersection] = []
////                            
//                            for var intersection in step.intersections! {
//                                
//                                print("intersections rioad:" + step.intersections!.description)
//                                
//                                intersection.headings = [0]
//                                intersection.approachIndex = 0
//                                intersection.outletIndex = 0
//                                intersection.outletIndexes = IndexSet(integer: 0)
//                                intersection.foreignMembers = [:]
//                                
//                                var yuy = MapboxDirections.Intersection(location: step.maneuverLocation, headings: [0], approachIndex: 0, outletIndex: 0, outletIndexes: IndexSet(integer: 0), approachLanes: nil, usableApproachLanes: nil, preferredApproachLanes: nil, usableLaneIndication: nil)
//                                
//                                intersection.location = step.maneuverLocation
//                                intersection.outletMapboxStreetsRoadClass = nil
//                                intersection.regionCode = nil
//                                intersection.isUrban = nil
//                                
//                                intersection = yuy
//                                
//                                newIntersections.append(yuy)
//                                
//                                //                            step.instructionsDisplayedAlongStep = []
////                                step.finalHeading = nil
//                                //                            step.initialHeading = nil
//                                //                            step.instructionsSpokenAlongStep = []
//                                //                            step.intersections = nil
//                                //                            step.names = nil
//                                //                            step.speedLimitUnit = nil
//                                //                            step.codes = nil
//                                //                            step.destinationCodes = nil
//                                //                            step.destinations = nil
//                                //                            step.drivingSide = .left
//                                //                            step.exitCodes = nil
//                                //                            step.exitIndex = nil
//                                //                            step.exitNames = nil
//                                //                            step.phoneticExitNames = nil
//                                //                            step.phoneticNames = nil
//                                //                            step.speedLimitSignStandard = nil
//                                //                            step.typicalTravelTime = nil
//                                //                            step.administrativeAreaContainerByIntersection = nil
//                                //                            step.segmentIndicesByIntersection = nil
//                                
//                                
//                                
//                                //                            step.intersections =  [MapboxDirections.Intersection(location: step.maneuverLocation, headings: [0], approachIndex: 0, outletIndex: 0, outletIndexes: IndexSet(integer: 0), approachLanes: nil, usableApproachLanes: nil, preferredApproachLanes: nil, usableLaneIndication: nil)]
//                            }
//                            
//                            print("instructionsDisplayedAlongStep count:" + String(step.instructionsDisplayedAlongStep!.count))
//                            
//                            step.intersections = newIntersections
////                            
//                        }
                        
                        
                        completionHandler(session, .success(result))
                    }
                } catch {
                    DispatchQueue.main.async {
                        let bailError = DirectionsError(code: nil, message: nil, response: response, underlyingError: error)
                        completionHandler(session, .failure(bailError))
                    }
                }
            }
        }
        requestTask.priority = 1
        requestTask.resume()
        
        return requestTask
    }
    
//    @discardableResult
//    open func calculate3(_ options: RouteOptions, completionHandler: @escaping RouteCompletionHandler) -> URLSessionDataTask {
//        options.fetchStartDate = Date()
//        let session = (options: options as DirectionsOptions, credentials: self.credentials)
//
//        // Create POST request for GraphHopper
//        let request = createGraphHopperRequest(forCalculating: options)
//        let requestTask = urlSession.dataTask(with: request) { (possibleData, possibleResponse, possibleError) in
//            if let urlError = possibleError as? URLError {
//                DispatchQueue.main.async {
//                    completionHandler(session, .failure(.network(urlError)))
//                }
//                return
//            }
////
//            guard let response = possibleResponse, ["application/json", "text/html"].contains(response.mimeType) else {
//                DispatchQueue.main.async {
//                    completionHandler(session, .failure(.invalidResponse(possibleResponse)))
//                }
//                return
//            }
////
//            guard let data = possibleData else {
//                DispatchQueue.main.async {
//                    completionHandler(session, .failure(.noData))
//                }
//                return
//            }
////
//            self.processingQueue.async {
//                do {
//                    let decoder = JSONDecoder()
//                    let routes = try decoder.decode(GraphHopperRouteResponse.self, from: data)
//                    
//                    DispatchQueue.main.async {
//                        let routeResponse = self.convertToRouteResponse(routes, with: options)
//                        completionHandler(session, .success(routeResponse))
//                    }
//                } catch {
//                    DispatchQueue.main.async {
//                        let bailError = DirectionsError(code: nil, message: nil, response: response, underlyingError: error)
//                        completionHandler(session, .failure(bailError))
//                    }
//                }
//            }
//        }
//        requestTask.priority = 1
//        requestTask.resume()
//
//        return requestTask
//    }
    
    @discardableResult
    open func calculate2(_ options: RouteOptions, completionHandler: @escaping RouteCompletionHandler) -> URLSessionDataTask {
        options.fetchStartDate = Date()
        let session = (options: options as DirectionsOptions, credentials: self.credentials)

        // Create POST request for GraphHopper
        let request = createGraphHopperRequest(forCalculating: options)
        let requestTask = urlSession.dataTask(with: request) { (possibleData, possibleResponse, possibleError) in
            if let urlError = possibleError as? URLError {
                DispatchQueue.main.async {
                    completionHandler(session, .failure(.network(urlError)))
                }
                return
            }
//
            guard let response = possibleResponse, ["application/json", "text/html"].contains(response.mimeType) else {
                DispatchQueue.main.async {
                    completionHandler(session, .failure(.invalidResponse(possibleResponse)))
                }
                return
            }
//
            guard let data = possibleData else {
                DispatchQueue.main.async {
                    completionHandler(session, .failure(.noData))
                }
                return
            }
//
            self.processingQueue.async {
                do {
                    let decoder = JSONDecoder()
                    let routes = try decoder.decode(GraphHopperRouteResponse.self, from: data)
                    
                    DispatchQueue.main.async {
                        let routeResponse = self.convertToRouteResponse(routes, with: options)
                        completionHandler(session, .success(routeResponse))
                    }
                } catch {
                    DispatchQueue.main.async {
                        let bailError = DirectionsError(code: nil, message: nil, response: response, underlyingError: error)
                        completionHandler(session, .failure(bailError))
                    }
                }
            }
        }
        requestTask.priority = 1
        requestTask.resume()

        return requestTask
    }
    
//    open func calculate(_ options: RouteOptions, completionHandler: @escaping RouteCompletionHandler) -> URLSessionDataTask {
//        options.fetchStartDate = Date()
//        let session = (options: options as DirectionsOptions, credentials: self.credentials)
//
//        let request = createGraphHopperRequest(forCalculating: options)
//        let requestTask = urlSession.dataTask(with: request) { (possibleData, possibleResponse, possibleError) in
//            if let urlError = possibleError as? URLError {
//                DispatchQueue.main.async {
//                    completionHandler(session, .failure(.network(urlError)))
//                }
//                return
//            }
//
//            guard let response = possibleResponse, ["application/json", "text/html"].contains(response.mimeType) else {
//                DispatchQueue.main.async {
//                    completionHandler(session, .failure(.invalidResponse(possibleResponse)))
//                }
//                return
//            }
//
//            guard let data = possibleData else {
//                DispatchQueue.main.async {
//                    completionHandler(session, .failure(.noData))
//                }
//                return
//            }
//
//            self.processingQueue.async {
//                do {
//                    let decoder = JSONDecoder()
//                    let graphHopperResponse = try decoder.decode(GraphHopperRouteResponse.self, from: data)
//                    var uniqueIndices = Set<Int>()
//                    var selectedCoordinates: [LocationCoordinate2D] = []
//
//                    for path in graphHopperResponse.paths {
//                        let decodedPoints = self.decodePolyline(path.points, precision: 1e5) ?? []
//                        let instructionIndices = path.instructions.flatMap { $0.interval }
//                        uniqueIndices.formUnion(instructionIndices)
//                        
//                        let uniqueCoordinates = Array(uniqueIndices).sorted().compactMap { index in
//                            index < decodedPoints.count ? decodedPoints[index] : nil
//                        }
//                        
//                        // Limiting to 100 coordinates if there are more
//                        selectedCoordinates.append(contentsOf: uniqueCoordinates)
//                    }
//                    
//                    selectedCoordinates = self.selectCoordinates(selectedCoordinates, maxCount: 100)
//
//                    DispatchQueue.main.async {
//                        var matchOptions = NavigationMatchOptions(coordinates: selectedCoordinates)
//                        matchOptions.waypointIndices = [0, selectedCoordinates.count - 1]
//                        matchOptions.includesSpokenInstructions = true
//                        matchOptions.includesVisualInstructions = true
//                        matchOptions.includesSteps = true
//                        self.calculateRoutes(matching: matchOptions) { matchSession, matchResult in
//                            matchSession.options = RouteOptions(matchOptions: matchSession.options)
////                            let routeOptions = RouteOptions(matchOptions: matchSession.options)
//                            completionHandler(matchSession, matchResult)
//                        }
//                    }
//                } catch {
//                    DispatchQueue.main.async {
//                        let bailError = DirectionsError(code: nil, message: nil, response: response, underlyingError: error)
//                        completionHandler(session, .failure(bailError))
//                    }
//                }
//            }
//        }
//        requestTask.priority = 1
//        requestTask.resume()
//
//        return requestTask
//    }
    
    open func calculate(_ options: RouteOptions, completionHandler: @escaping RouteCompletionHandler) -> URLSessionDataTask {
        options.fetchStartDate = Date()
        let session = (options: options as DirectionsOptions, credentials: self.credentials)

        let request = createGraphHopperRequest(forCalculating: options)
        let requestTask = urlSession.dataTask(with: request) { (possibleData, possibleResponse, possibleError) in
            if let urlError = possibleError as? URLError {
                DispatchQueue.main.async {
                    completionHandler(session, .failure(.network(urlError)))
                }
                return
            }

            guard let response = possibleResponse, ["application/json", "text/html"].contains(response.mimeType) else {
                DispatchQueue.main.async {
                    completionHandler(session, .failure(.invalidResponse(possibleResponse)))
                }
                return
            }

            guard let data = possibleData else {
                DispatchQueue.main.async {
                    completionHandler(session, .failure(.noData))
                }
                return
            }

            self.processingQueue.async {
                do {
                    let decoder = JSONDecoder()
                    let graphHopperResponse = try decoder.decode(GraphHopperRouteResponse.self, from: data)
                    var uniqueIndices = Set<Int>()
                    var selectedCoordinates: [LocationCoordinate2D] = []

                    for path in graphHopperResponse.paths {
                        let decodedPoints = self.decodePolyline(path.points, precision: 1e5) ?? []
                        let instructionIndices = path.instructions.flatMap { $0.interval }
                        uniqueIndices.formUnion(instructionIndices)
                        
                        let uniqueCoordinates = Array(uniqueIndices).sorted().compactMap { index in
                            index < decodedPoints.count ? decodedPoints[index] : nil
                        }
                        
                        // Limiting to 100 coordinates if there are more
//                        selectedCoordinates.append(contentsOf: uniqueCoordinates)
                        selectedCoordinates.append(contentsOf: decodedPoints)
                        
                    }
                    
                    selectedCoordinates = self.selectCoordinates(selectedCoordinates, maxCount: 100)
                    
                    var selectedWayPoints:[Waypoint] = []
                    
                    var i = 0
                    for coordinate in selectedCoordinates {
                        var waypoint = Waypoint(coordinate: coordinate)
//                        if i == 0 {
//                            waypoint.separatesLegs = true
//                        } else if i == selectedCoordinates.count-1 {
//                            waypoint.separatesLegs = true
//                        } else {
//                            waypoint.separatesLegs = false
//                        }
                        waypoint.separatesLegs = false
//                        waypoint.coordinateAccuracy = LocationAccuracy(100)
                        selectedWayPoints.append(waypoint)
                    }
                
//                    DispatchQueue.main.async {
////                        let routeResponse = convertToRouteResponse(routes, with: options)
//                        completionHandler(session, .success(selectedCoordinates))
//                    }
                
//                    completionHandler(matchSession, matchResult)
//                    selectedWayPoints = [selectedWayPoints.first!, selectedWayPoints[10], selectedWayPoints.last!]

                    DispatchQueue.main.async {
                        var matchOptions = MatchOptions(waypoints: selectedWayPoints)
//                        matchOptions.waypointIndices = [0, selectedCoordinates.count - 1]
                        matchOptions.includesSpokenInstructions = true
                        matchOptions.includesVisualInstructions = true
                        matchOptions.includesSteps = true
//                        matchOptions.resamplesTraces = true
                        matchOptions.routeShapeResolution = .full
                        matchOptions.profileIdentifier = .automobile
//                        matchOptions.locale = .
//                        matchOptions.waypoints = selectedWayPoints
//                        var oldWaypoints = options.waypoints
//                        options.waypoints = selectedWayPoints
//                        self.calculatewtf(options) { matchSession, matchResult in
//                        self.calculate(matchOptions) { (matchSession: (options: DirectionsOptions, credentials: Credentials), matchResult: Result<MapMatchingResponse, DirectionsError>)  in
//                            
//                            switch matchResult {
//                                case .success(let matches):
//                                    do {
//                                        var t = RouteOptions(matchOptions: matchOptions)
//                                        var routeResponse = try RouteResponse(matching: matches, options: matchOptions, credentials: matchSession.credentials)
//                                        routeResponse.options = .route(t)
//                                        completionHandler(matchSession, .success(routeResponse))
//                                    } catch {
////                                        completionHandler(matchSession, .failure(.unknown(response: error as! URLResponse)))
//                                    }
//                                case .failure(let error):
//                                    completionHandler(matchSession, .failure(error))
//                                }
//
//                            
//////                            matchResult.
//////                            matchSession.options = RouteOptions(matchOptions: matchSession.options)
////                            var routeResponse = RouteResponse(matching: matchResult., options: matchOptions, credentials: matchSession.credentials)
//////                            let routeOptions = RouteOptions(matchOptions: matchSession.options)
//////                            options.waypoints = oldWaypoints
////                            completionHandler(matchSession, routeResponse)
//                        }
                        
                        self.calculateRoutes(matching: matchOptions) { (matchSession, matchResult)  in
                            
                            switch matchResult {
                                case .success(var matches):
                                    do {
                                        var t = RouteOptions(matchOptions: matchOptions)
                                        /*var routeResponse = try RouteResponse(matching: matches, options: matchOptions, credentials: matchSession.credentials)*/
//                                        routeResponse.options = .route(t)
                                        
//                                        matchResult.
                                        matches.options = .route(t)
                                        matches.options
                                        matches.identifier = "blurnywerby"
                                        completionHandler(matchSession, .success(matches))
                                    } catch {
//                                        completionHandler(matchSession, .failure(.unknown(response: error as! URLResponse)))
                                    }
                                case .failure(let error):
                                    completionHandler(matchSession, .failure(error))
                                }

                            
////                            matchResult.
////                            matchSession.options = RouteOptions(matchOptions: matchSession.options)
//                            var routeResponse = RouteResponse(matching: matchResult., options: matchOptions, credentials: matchSession.credentials)
////                            let routeOptions = RouteOptions(matchOptions: matchSession.options)
////                            options.waypoints = oldWaypoints
//                            completionHandler(matchSession, routeResponse)
                        }
                        
                    }
                } catch {
                    DispatchQueue.main.async {
                        let bailError = DirectionsError(code: nil, message: nil, response: response, underlyingError: error)
                        completionHandler(session, .failure(bailError))
                    }
                }
            }
        }
        requestTask.priority = 1
        requestTask.resume()

        return requestTask
    }

    // Helper function to select a limited number of coordinates evenly
    func selectCoordinates(_ coordinates: [LocationCoordinate2D], maxCount: Int) -> [LocationCoordinate2D] {
        if coordinates.count <= maxCount {
            return coordinates
        }
        let factor = ceil(Double(coordinates.count) / Double(maxCount))
        return stride(from: 0, to: coordinates.count, by: Int.Stride(factor)).map { coordinates[$0] }
    }

    
    private func createGraphHopperRequest(forCalculating options: RouteOptions) -> URLRequest {
        let url = URL(string: "http://routingserver-env.eba-ij6x6fhx.us-east-2.elasticbeanstalk.com:8989/route")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var firstWaypoint = options.waypoints.first
        var lastWaypoint = options.waypoints.last
        
        
//        var points = []
        
//        let points = options.waypoints.map { [$0.coordinate.longitude, $0.coordinate.latitude] }
        let points = [[firstWaypoint!.coordinate.longitude, firstWaypoint!.coordinate.latitude], [lastWaypoint!.coordinate.longitude, lastWaypoint!.coordinate.latitude]]
        let payload = GraphHopperRequest(points: points)
        request.httpBody = try? JSONEncoder().encode(payload)

        return request
    }
    
    func convertToRouteResponse(_ graphHopperResponse: GraphHopperRouteResponse, with options: RouteOptions) -> RouteResponse {
        var routes = [Route]()
        var waypoints = [Waypoint]()

        for path in graphHopperResponse.paths {
            let coordinates: [LocationCoordinate2D] = decodePolyline(path.points, precision: 1e5) ?? []
            waypoints = coordinates.map { Waypoint(coordinate: $0) }

            let distance = path.distance
            let expectedTravelTime = TimeInterval(path.time / 1000)  // Convert ms to seconds

            var legs = [RouteLeg]()
            var steps = [RouteStep]()

            // Check if instructions exist; if they don't, this will skip processing them
//            let instructions = path.instructions {
            var first = true
            for instruction in path.instructions {
                // Extract coordinates for the step based on interval indices provided
                if instruction.interval.count == 2,
                   instruction.interval[0] < coordinates.count,
                   instruction.interval[1] < coordinates.count {
                    
                    let start = instruction.interval[0]
                    let end = instruction.interval[1]

                    
                    let stepCoordinatesSlice = coordinates[start...end]
                    let stepCoordinates = Array(stepCoordinatesSlice)
                    let lineString = LineString(stepCoordinates)
                    
                    let maneuverLocation = stepCoordinates.first ?? LocationCoordinate2D(latitude: 0, longitude: 0)
                    
                    let (maneuverType, maneuverDirection) = mapGraphHopperSignToMapbox(instruction.sign)

                    
                    var exitNames: [String]? = nil
                    var exitNumbers: [String]? = nil

                    // Handling roundabout exits and exit numbers
                    if maneuverType == .takeRoundabout || maneuverType == .exitRoundabout {
                        if let exitNumber = instruction.exit_number {
                            exitNumbers = [String(exitNumber)]
                            exitNames = [instruction.street_name]  // Assuming street_name gives the road name after the exit
                        }
                    }

                    let visual = VisualInstructionBanner(
                        distanceAlongStep: instruction.distance,
                        primary: VisualInstruction(
                            text: instruction.text,
                            maneuverType: maneuverType,
                            maneuverDirection: maneuverDirection,
                            components: [VisualInstruction.Component.text(text: VisualInstruction.Component.TextRepresentation(text: instruction.text, abbreviation: nil, abbreviationPriority: nil))]// Additional components can be added here if needed
                        ),
                        secondary: nil,
                        tertiary: nil,
                        quaternary: nil,
                        drivingSide: .left
                    )

                    let audio = SpokenInstruction(
                        distanceAlongStep: instruction.distance,
                        text: instruction.text,
                        ssmlText: instruction.text  // Modify if different SSML text is required
                    )

                    
                        let step = RouteStep(
                            transportType: .automobile, // Assuming mode of transport; modify as needed
                            maneuverLocation: maneuverLocation,
                            maneuverType: .turn, // You may need a function to map from sign to ManeuverType
                            maneuverDirection: maneuverDirection,
                            instructions: instruction.text,
//                            instructionsDisplayedAlongStep: [visual],
//                            instructionsSpokenAlongStep: [audio],
                            drivingSide: .left, // Assume 'right'; adjust based on actual data or settings
                            distance: instruction.distance,
                            expectedTravelTime: TimeInterval(instruction.time / 1000),
                            intersections: [
                                MapboxDirections.Intersection(location: maneuverLocation, headings: [0], approachIndex: 0, outletIndex: 0, outletIndexes: IndexSet(integer: 0), approachLanes: nil, usableApproachLanes: nil, preferredApproachLanes: nil, usableLaneIndication: nil),
                                MapboxDirections.Intersection(location: stepCoordinates.last!, headings: [0], approachIndex: 0, outletIndex: 0, outletIndexes: IndexSet(integer: 0), approachLanes: nil, usableApproachLanes: nil, preferredApproachLanes: nil, usableLaneIndication: nil)
                                           ]
                        )
                    step.instructionsDisplayedAlongStep = [visual]
                    step.instructionsSpokenAlongStep = [audio]
                    
//                    let step = RouteStep(
//                        transportType: .automobile,
//                        maneuverLocation: stepCoordinates.last ?? LocationCoordinate2D(latitude: 0, longitude: 0),
//                        maneuverType: first ? ManeuverType.depart : maneuverType,
//                        maneuverDirection: maneuverDirection,
//                        instructions: instruction.text,
//                        initialHeading: 0,
//                        finalHeading: 0,
//                        drivingSide: .left,
//                        exitCodes: exitNumbers,
//                        exitNames: exitNames,
//                        phoneticExitNames: exitNames,
//                        distance: instruction.distance,
//                        expectedTravelTime: TimeInterval(instruction.time / 1000),
//                        typicalTravelTime: nil,
//                        names: nil,
//                        phoneticNames: nil,
//                        codes: nil,
//                        destinationCodes: nil,
//                        destinations: nil,
//                        intersections: [MapboxDirections.Intersection(location: maneuverLocation, headings: [0], approachIndex: 0, outletIndex: 0, outletIndexes: IndexSet(integer: 0), approachLanes: nil, usableApproachLanes: nil, preferredApproachLanes: nil, usableLaneIndication: nil)],
//                        speedLimitSignStandard: nil,
//                        speedLimitUnit: UnitSpeed.kilometersPerHour,
//                        instructionsSpokenAlongStep: [audio],
//                        instructionsDisplayedAlongStep: [visual],
//                        administrativeAreaContainerByIntersection: nil,
//                        segmentIndicesByIntersection: nil
//                    )
                    
                    first = false
                    
//                        let step = RouteStep(
//                            transportType: .automobile,
//                            maneuverLocation: stepCoordinates.first ?? LocationCoordinate2D(latitude: 0, longitude: 0),
//                            maneuverType: maneuverType,
//                            maneuverDirection: maneuverDirection,
//                            instructions: instruction.text,
//                            instructionsDisplayedAlongStep: [visual],
//                            instructionsSpokenAlongStep: [audio],
//                            drivingSide: .right, // Assume right; this should be determined based on the locale or specific data
//                            distance: instruction.distance,
//                            expectedTravelTime: TimeInterval(instruction.time / 1000), // Convert ms to seconds
//                            exitNames: exitNames,
//                            exitCodes: exitNumbers
//                        )
                    
                    step.shape = lineString
//                        step.
                    
                    steps.append(step)
                }
            }
            
            
            
            let leg = RouteLeg(
                steps: steps,
                name: path.instructions[0].text,
                distance: path.distance,
                expectedTravelTime: TimeInterval(path.time / 1000),
                profileIdentifier: .automobile
            )
//            leg.
            leg.destination = waypoints.last
//            leg.segmentRangesByStep
            legs.append(leg)

            
//            }

            let route = Route(
                legs: legs,
                shape: LineString(coordinates),
                distance: distance,
                expectedTravelTime: expectedTravelTime
            )
            
            routes.append(route)
        }

        let routeResponse = RouteResponse(
            httpResponse: nil,
            identifier: UUID().uuidString,
            routes: routes,
            waypoints: waypoints,
            options: .route(options),
            credentials: self.credentials  // Assuming credentials are a property of options
        )

        return routeResponse
    }
    
    
    func mapGraphHopperSignToMapbox(_ sign: Int) -> (ManeuverType, ManeuverDirection) {
//        return (.turn, .uTurn)
        switch sign {
        case -8, 8:
            return (.turn, .uTurn)
        case -7, 7:
            return (.continue, sign < 0 ? .left : .right)
        case -3, 3:
            return (.turn, sign < 0 ? .sharpLeft : .sharpRight)
        case -2, 2:
            return (.turn, sign < 0 ? .left : .right)
        case -1, 1:
            return (.turn, sign < 0 ? .slightLeft : .slightRight)
        case 0:
            return (.continue, .straightAhead)
        case 4:
            return (.arrive, .straightAhead) // Modify based on context
        case -6:
            return (.exitRoundabout, .left) // Adjust based on actual data
        case 6:
            return (.takeRoundabout, .left) // Adjust based on actual data
        default:
            return (.default, .straightAhead)
        }
    }


//    func convertToRouteResponse(_ graphHopperResponse: GraphHopperRouteResponse, with options: RouteOptions) -> RouteResponse {
//        var routes = [Route]()
//        var waypoints = [Waypoint]()
//
//        for path in graphHopperResponse.paths {
//            // Decode the polyline to get coordinates if points are encoded
//            let coordinates: [LocationCoordinate2D] = decodePolyline(path.points, precision: 1e5) ?? []
//
//            // Create waypoints from the decoded points
//            waypoints = coordinates.map { Waypoint(coordinate: $0) }
//
//            // Calculate additional route properties if necessary
//            let distance = path.distance
//            let expectedTravelTime = TimeInterval(path.time / 1000)  // Convert from milliseconds to seconds if needed
//
//            // Assuming you have a Route struct that takes these parameters
//            let route = Route(
//                legs: [], // You might need to convert instructions to legs
//                shape: LineString(coordinates),
//                distance: distance,
//                expectedTravelTime: expectedTravelTime
//            )
//            routes.append(route)
//        }
//
//        // Assume RouteResponse can be initialized with these parameters
//        let routeResponse = RouteResponse(
//            httpResponse: nil, // HTTP response not directly available
//            identifier: UUID().uuidString, // Create a new UUID for identifier
//            routes: routes,
//            waypoints: waypoints,
//            options: .route(options), // Assuming this is how you encapsulate the options
//            credentials: self.credentials
//        )
//
//        return routeResponse
//    }

    /// Helper function to decode polyline
    func decodePolyline(_ encodedPolyline: String, precision: Double) -> [LocationCoordinate2D]? {
        return Polyline(encodedPolyline: encodedPolyline).coordinates
    }
    
    struct GraphHopperRequest: Codable {
        let points: [[Double]]
        let details: [String] = ["road_class", "road_environment", "max_speed", "average_speed"]
        let profile: String = "car"
    }


    
    /**
     Begins asynchronously calculating matches using the given options and delivers the results to a closure.
     
     This method retrieves the matches asynchronously from the [Mapbox Map Matching API](https://docs.mapbox.com/api/navigation/#map-matching) over a network connection. If a connection error or server error occurs, details about the error are passed into the given completion handler in lieu of the routes.
     
     To get `Route`s based on these matches, use the `calculateRoutes(matching:completionHandler:)` method instead.
     
     - parameter options: A `MatchOptions` object specifying the requirements for the resulting matches.
     - parameter completionHandler: The closure (block) to call with the resulting matches. This closure is executed on the application’s main thread.
     - returns: The data task used to perform the HTTP request. If, while waiting for the completion handler to execute, you no longer want the resulting matches, cancel this task.
     */
    @discardableResult open func calculate(_ options: MatchOptions, completionHandler: @escaping MatchCompletionHandler) -> URLSessionDataTask {
        options.fetchStartDate = Date()
        let session = (options: options as DirectionsOptions, credentials: self.credentials)
        let request = urlRequest(forCalculating: options)
        let requestTask = urlSession.dataTask(with: request) { (possibleData, possibleResponse, possibleError) in
            
            if let urlError = possibleError as? URLError {
                DispatchQueue.main.async {
                    completionHandler(session, .failure(.network(urlError)))
                }
                return
            }
            
            guard let response = possibleResponse, response.mimeType == "application/json" else {
                DispatchQueue.main.async {
                    completionHandler(session, .failure(.invalidResponse(possibleResponse)))
                    
                }
                return
            }
            
            guard let data = possibleData else {
                DispatchQueue.main.async {
                    completionHandler(session, .failure(.noData))
                }
                return
            }
            
            
            self.processingQueue.async {
                do {
                    let decoder = JSONDecoder()
                    decoder.userInfo = [.options: options,
                                        .credentials: self.credentials]
                    guard let disposition = try? decoder.decode(ResponseDisposition.self, from: data) else {
                          let apiError = DirectionsError(code: nil, message: nil, response: possibleResponse, underlyingError: possibleError)
                          DispatchQueue.main.async {
                            completionHandler(session, .failure(apiError))
                          }
                          return
                      }
                      
                      guard disposition.code == "Ok" else {
                          let apiError = DirectionsError(code: disposition.code, message: disposition.message, response: response, underlyingError: possibleError)
                          DispatchQueue.main.async {
                            completionHandler(session, .failure(apiError))
                          }
                          return
                      }
                    
                    let response = try decoder.decode(MapMatchingResponse.self, from: data)
                    
                    guard response.matches != nil else {
                        DispatchQueue.main.async {
                            completionHandler(session, .failure(.unableToRoute))
                        }
                        return
                    }
                                        
                    DispatchQueue.main.async {
                        completionHandler(session, .success(response))
                    }
                } catch {
                    DispatchQueue.main.async {
                        let caughtError = DirectionsError.unknown(response: response, underlying: error, code: nil, message: nil)
                        completionHandler(session, .failure(caughtError))
                    }
                }
            }
        }
        requestTask.priority = 1
        requestTask.resume()
        
        return requestTask
    }
    
    /**
     Begins asynchronously calculating routes that match the given options and delivers the results to a closure.
     
     This method retrieves the routes asynchronously from the [Mapbox Map Matching API](https://docs.mapbox.com/api/navigation/#map-matching) over a network connection. If a connection error or server error occurs, details about the error are passed into the given completion handler in lieu of the routes.
     
     To get the `Match`es that these routes are based on, use the `calculate(_:completionHandler:)` method instead.
     
     - parameter options: A `MatchOptions` object specifying the requirements for the resulting match.
     - parameter completionHandler: The closure (block) to call with the resulting routes. This closure is executed on the application’s main thread.
     - returns: The data task used to perform the HTTP request. If, while waiting for the completion handler to execute, you no longer want the resulting routes, cancel this task.
     */
    @discardableResult open func calculateRoutes(matching options: MatchOptions, completionHandler: @escaping RouteCompletionHandler) -> URLSessionDataTask {
        options.fetchStartDate = Date()
        let session = (options: options as DirectionsOptions, credentials: self.credentials)
        let request = urlRequest(forCalculating: options)
        let requestTask = urlSession.dataTask(with: request) { (possibleData, possibleResponse, possibleError) in
            
             if let urlError = possibleError as? URLError {
                 DispatchQueue.main.async {
                    completionHandler(session, .failure(.network(urlError)))
                 }
                 return
             }
            
            guard let response = possibleResponse, ["application/json", "text/html"].contains(response.mimeType) else  {
                DispatchQueue.main.async {
                    completionHandler(session, .failure(.invalidResponse(possibleResponse)))
                }
                return
            }
            
            guard let data = possibleData else {
                DispatchQueue.main.async {
                    completionHandler(session, .failure(.noData))
                }
                return
            }
            
            self.processingQueue.async {
                do {
                    let decoder = JSONDecoder()
                    decoder.userInfo = [.options: options,
                                        .credentials: self.credentials]
                    
                    
                    guard let disposition = try? decoder.decode(ResponseDisposition.self, from: data) else {
                        let apiError = DirectionsError(code: nil, message: nil, response: possibleResponse, underlyingError: possibleError)
                        DispatchQueue.main.async {
                            completionHandler(session, .failure(apiError))
                        }
                        return
                    }
                    
                    guard disposition.code == "Ok" else {
                        let apiError = DirectionsError(code: disposition.code, message: disposition.message, response: response, underlyingError: possibleError)
                        DispatchQueue.main.async {
                            completionHandler(session, .failure(apiError))
                        }
                        return
                    }
                    
                    let result = try decoder.decode(MapMatchingResponse.self, from: data)
                    
                    let routeResponse = try RouteResponse(matching: result, options: options, credentials: self.credentials)
                    guard routeResponse.routes != nil else {
                        DispatchQueue.main.async {
                            completionHandler(session, .failure(.unableToRoute))
                        }
                        return
                    }
                    
                    DispatchQueue.main.async {
                        completionHandler(session, .success(routeResponse))
                    }
                } catch {
                    DispatchQueue.main.async {
                        let bailError = DirectionsError(code: nil, message: nil, response: response, underlyingError: error)
                        completionHandler(session, .failure(bailError))
                    }
                }
            }
        }
        requestTask.priority = 1
        requestTask.resume()
        
        return requestTask
    }
    
    /**
     Begins asynchronously refreshing the route with the given identifier, optionally starting from an arbitrary leg along the route.
     
     This method retrieves skeleton route data asynchronously from the Mapbox Directions Refresh API over a network connection. If a connection error or server error occurs, details about the error are passed into the given completion handler in lieu of the routes.
     
     - precondition: Set `RouteOptions.refreshingEnabled` to `true` when calculating the original route.
     
     - parameter responseIdentifier: The `RouteResponse.identifier` value of the `RouteResponse` that contains the route to refresh.
     - parameter routeIndex: The index of the route to refresh in the original `RouteResponse.routes` array.
     - parameter startLegIndex: The index of the leg in the route at which to begin refreshing. The response will omit any leg before this index and refresh any leg from this index to the end of the route. If this argument is omitted, the entire route is refreshed.
     - parameter completionHandler: The closure (block) to call with the resulting skeleton route data. This closure is executed on the application’s main thread.
     - returns: The data task used to perform the HTTP request. If, while waiting for the completion handler to execute, you no longer want the resulting skeleton routes, cancel this task.
     */
    @discardableResult open func refreshRoute(responseIdentifier: String, routeIndex: Int, fromLegAtIndex startLegIndex: Int = 0, completionHandler: @escaping RouteRefreshCompletionHandler) -> URLSessionDataTask? {
        _refreshRoute(responseIdentifier: responseIdentifier,
                      routeIndex: routeIndex,
                      fromLegAtIndex: startLegIndex,
                      currentRouteShapeIndex: nil,
                      completionHandler: completionHandler)
    }

    /**
     Begins asynchronously refreshing the route with the given identifier, optionally starting from an arbitrary leg and point along the route.
     
     This method retrieves skeleton route data asynchronously from the Mapbox Directions Refresh API over a network connection. If a connection error or server error occurs, details about the error are passed into the given completion handler in lieu of the routes.
     
     - precondition: Set `RouteOptions.refreshingEnabled` to `true` when calculating the original route.
     
     - parameter responseIdentifier: The `RouteResponse.identifier` value of the `RouteResponse` that contains the route to refresh.
     - parameter routeIndex: The index of the route to refresh in the original `RouteResponse.routes` array.
     - parameter startLegIndex: The index of the leg in the route at which to begin refreshing. The response will omit any leg before this index and refresh any leg from this index to the end of the route. If this argument is omitted, the entire route is refreshed.
     - parameter currentRouteShapeIndex: The index of the route geometry at which to begin refreshing. Indexed geometry must be contained by the leg at `startLegIndex`.
     - parameter completionHandler: The closure (block) to call with the resulting skeleton route data. This closure is executed on the application’s main thread.
     - returns: The data task used to perform the HTTP request. If, while waiting for the completion handler to execute, you no longer want the resulting skeleton routes, cancel this task.
     */
    @discardableResult open func refreshRoute(responseIdentifier: String, routeIndex: Int, fromLegAtIndex startLegIndex: Int = 0, currentRouteShapeIndex: Int, completionHandler: @escaping RouteRefreshCompletionHandler) -> URLSessionDataTask? {
        _refreshRoute(responseIdentifier: responseIdentifier,
                      routeIndex: routeIndex,
                      fromLegAtIndex: startLegIndex,
                      currentRouteShapeIndex: currentRouteShapeIndex,
                      completionHandler: completionHandler)
    }

    private func _refreshRoute(responseIdentifier: String, routeIndex: Int, fromLegAtIndex startLegIndex: Int, currentRouteShapeIndex: Int?, completionHandler: @escaping RouteRefreshCompletionHandler) -> URLSessionDataTask? {
        let request: URLRequest
        if let currentRouteShapeIndex = currentRouteShapeIndex {
            request = urlRequest(forRefreshing: responseIdentifier, routeIndex: routeIndex, fromLegAtIndex: startLegIndex, currentRouteShapeIndex: currentRouteShapeIndex)
        } else {
            request = urlRequest(forRefreshing: responseIdentifier, routeIndex: routeIndex, fromLegAtIndex: startLegIndex)
        }
        let requestTask = urlSession.dataTask(with: request) { (possibleData, possibleResponse, possibleError) in
            if let urlError = possibleError as? URLError {
                DispatchQueue.main.async {
                    completionHandler(self.credentials, .failure(.network(urlError)))
                }
                return
            }
            
            guard let response = possibleResponse, ["application/json", "text/html"].contains(response.mimeType) else {
                DispatchQueue.main.async {
                    completionHandler(self.credentials, .failure(.invalidResponse(possibleResponse)))
                }
                return
            }
            
            guard let data = possibleData else {
                DispatchQueue.main.async {
                    completionHandler(self.credentials, .failure(.noData))
                }
                return
            }
            
            self.processingQueue.async {
                do {
                    let decoder = JSONDecoder()
                    decoder.userInfo = [
                        .responseIdentifier: responseIdentifier,
                        .routeIndex: routeIndex,
                        .startLegIndex: startLegIndex,
                        .credentials: self.credentials,
                    ]
                    
                    guard let disposition = try? decoder.decode(ResponseDisposition.self, from: data) else {
                        let apiError = DirectionsError(code: nil, message: nil, response: possibleResponse, underlyingError: possibleError)

                        DispatchQueue.main.async {
                            completionHandler(self.credentials, .failure(apiError))
                        }
                        return
                    }
                    
                    guard (disposition.code == nil && disposition.message == nil) || disposition.code == "Ok" else {
                        let apiError = DirectionsError(code: disposition.code,
                                                       message: disposition.message,
                                                       response: response,
                                                       underlyingError: possibleError,
                                                       refreshTTL: disposition.refreshTTL)
                        DispatchQueue.main.async {
                            completionHandler(self.credentials, .failure(apiError))
                        }
                        return
                    }
                    
                    let result = try decoder.decode(RouteRefreshResponse.self, from: data)
                    
                    DispatchQueue.main.async {
                        completionHandler(self.credentials, .success(result))
                    }
                } catch {
                    DispatchQueue.main.async {
                        let bailError = DirectionsError(code: nil, message: nil, response: response, underlyingError: error)
                        completionHandler(self.credentials, .failure(bailError))
                    }
                }
            }
        }
        requestTask.priority = 1
        requestTask.resume()
        return requestTask
    }
    
    open func urlRequest(forRefreshing responseIdentifier: String, routeIndex: Int, fromLegAtIndex startLegIndex: Int) -> URLRequest {
        _urlRequest(forRefreshing: responseIdentifier,
                    routeIndex: routeIndex,
                    fromLegAtIndex: startLegIndex,
                    currentRouteShapeIndex: nil)
    }

    open func urlRequest(forRefreshing responseIdentifier: String, routeIndex: Int, fromLegAtIndex startLegIndex: Int, currentRouteShapeIndex: Int) -> URLRequest {
        _urlRequest(forRefreshing: responseIdentifier,
                    routeIndex: routeIndex,
                    fromLegAtIndex: startLegIndex,
                    currentRouteShapeIndex: currentRouteShapeIndex)
    }

    private func _urlRequest(forRefreshing responseIdentifier: String, routeIndex: Int, fromLegAtIndex startLegIndex: Int, currentRouteShapeIndex: Int?) -> URLRequest {
        var params: [URLQueryItem] = authenticationParams
        if let currentRouteShapeIndex = currentRouteShapeIndex {
            params.append(URLQueryItem(name: "current_route_geometry_index", value: String(currentRouteShapeIndex)))
        }

        var unparameterizedURL = URL(string: "directions-refresh/v1/\(ProfileIdentifier.automobileAvoidingTraffic.rawValue)", relativeTo: credentials.host)!
        unparameterizedURL.appendPathComponent(responseIdentifier)
        unparameterizedURL.appendPathComponent(String(routeIndex))
        unparameterizedURL.appendPathComponent(String(startLegIndex))
        var components = URLComponents(url: unparameterizedURL, resolvingAgainstBaseURL: true)!

        components.queryItems = params

        let getURL = components.url!
        var request = URLRequest(url: getURL)
        request.setupUserAgentString()
        return request
    }

    /**
     The GET HTTP URL used to fetch the routes from the API.
     
     After requesting the URL returned by this method, you can parse the JSON data in the response and pass it into the `Route.init(json:waypoints:profileIdentifier:)` initializer. Alternatively, you can use the `calculate(_:options:)` method, which automatically sends the request and parses the response.
     
     - parameter options: A `DirectionsOptions` object specifying the requirements for the resulting routes.
     - returns: The URL to send the request to.
     */
    open func url(forCalculating options: DirectionsOptions) -> URL {
        return url(forCalculating: options, httpMethod: "GET")
    }
    
    /**
     The HTTP URL used to fetch the routes from the API using the specified HTTP method.
     
     The query part of the URL is generally suitable for GET requests. However, if the URL is exceptionally long, it may be more appropriate to send a POST request to a URL without the query part, relegating the query to the body of the HTTP request. Use the `urlRequest(forCalculating:)` method to get an HTTP request that is a GET or POST request as necessary.
     
     After requesting the URL returned by this method, you can parse the JSON data in the response and pass it into the `Route.init(json:waypoints:profileIdentifier:)` initializer. Alternatively, you can use the `calculate(_:options:)` method, which automatically sends the request and parses the response.
     
     - parameter options: A `DirectionsOptions` object specifying the requirements for the resulting routes.
     - parameter httpMethod: The HTTP method to use. The value of this argument should match the `URLRequest.httpMethod` of the request you send. Currently, only GET and POST requests are supported by the API.
     - returns: The URL to send the request to.
     */
    open func url(forCalculating options: DirectionsOptions, httpMethod: String) -> URL {
        let includesQuery = httpMethod != "POST"
        var params = (includesQuery ? options.urlQueryItems : [])
        params.append(contentsOf: authenticationParams)

        let unparameterizedURL = URL(path: includesQuery ? options.path : options.abridgedPath, host: credentials.host)
        var components = URLComponents(url: unparameterizedURL, resolvingAgainstBaseURL: true)!
        components.queryItems = params
        return components.url!
    }
    
    /**
     The HTTP request used to fetch the routes from the API.
     
     The returned request is a GET or POST request as necessary to accommodate URL length limits.
     
     After sending the request returned by this method, you can parse the JSON data in the response and pass it into the `Route.init(json:waypoints:profileIdentifier:)` initializer. Alternatively, you can use the `calculate(_:options:)` method, which automatically sends the request and parses the response.
     
     - parameter options: A `DirectionsOptions` object specifying the requirements for the resulting routes.
     - returns: A GET or POST HTTP request to calculate the specified options.
     */
    open func urlRequest(forCalculating options: DirectionsOptions) -> URLRequest {
        if options.waypoints.count < 2 { assertionFailure("waypoints array requires at least 2 waypoints") }
        let getURL = self.url(forCalculating: options, httpMethod: "GET")
        var request = URLRequest(url: getURL)
        if getURL.absoluteString.count > MaximumURLLength {
            request.url = url(forCalculating: options, httpMethod: "POST")
            
            let body = options.httpBody.data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpMethod = "POST"
            request.httpBody = body
        }
        request.setupUserAgentString()
        return request
    }
}

/**
    Keys to pass to populate a `userInfo` dictionary, which is passed to the `JSONDecoder` upon trying to decode a `RouteResponse`, `MapMatchingResponse`or `RouteRefreshResponse`.
 */
public extension CodingUserInfoKey {
    static let options = CodingUserInfoKey(rawValue: "com.mapbox.directions.coding.routeOptions")!
    static let httpResponse = CodingUserInfoKey(rawValue: "com.mapbox.directions.coding.httpResponse")!
    static let credentials = CodingUserInfoKey(rawValue: "com.mapbox.directions.coding.credentials")!
    static let tracepoints = CodingUserInfoKey(rawValue: "com.mapbox.directions.coding.tracepoints")!
    
    static let responseIdentifier = CodingUserInfoKey(rawValue: "com.mapbox.directions.coding.responseIdentifier")!
    static let routeIndex = CodingUserInfoKey(rawValue: "com.mapbox.directions.coding.routeIndex")!
    static let startLegIndex = CodingUserInfoKey(rawValue: "com.mapbox.directions.coding.startLegIndex")!
}











struct GraphHopperRouteResponse: Codable {
    var paths: [Path]
    var hints: Hints
    var info: Info
}

struct Path: Codable {
    var distance: Double
    var weight: Double
    var time: Int
    var transfers: Int?
    var points_encoded: Bool
    var points_encoded_multiplier: Int?
    var bbox: [Double]
    var points: String
    var instructions: [Instruction]
    var legs: [Leg]?  // If there are any
    var details: Details
    var ascend: Double?
    var descend: Double?
    var snapped_waypoints: String?
}

struct Hints: Codable {
    var visited_nodes_sum: Int?
    var visited_nodes_average: Int?
}

struct Info: Codable {
    var copyrights: [String]
    var took: Int
    var road_data_time_stamp: String
}

struct Instruction: Codable {
    var street_ref: String?
    var distance: Double
    var heading: Double?
    var sign: Int
    var interval: [Int]
    var text: String
    var time: Int
    var street_name: String
    var exit_number: Int?
    var exited: Bool?
    var turn_angle: Double?
}

struct Leg: Codable {
    // Define according to the JSON structure expected for legs
}

struct Details: Codable {
    var road_environment: [DetailSegment]
    var road_class: [DetailSegment]
    var max_speed: [DetailSegment]
    var average_speed: [DetailSegment]
}

struct DetailSegment: Codable {
    var start: Int
    var end: Int
    var value: CodableValue

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        start = try container.decode(Int.self)
        end = try container.decode(Int.self)
        value = try container.decode(CodableValue.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(start)
        try container.encode(end)
        try container.encode(value)
    }
}

enum CodableValue: Codable {
    case int(Int)
    case string(String)
    case double(Double)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
        } else if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type for CodableValue")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let intVal):
            try container.encode(intVal)
        case .double(let doubleVal):
            try container.encode(doubleVal)
        case .string(let stringVal):
            try container.encode(stringVal)
        case .null:
            try container.encodeNil()
        }
    }
}

