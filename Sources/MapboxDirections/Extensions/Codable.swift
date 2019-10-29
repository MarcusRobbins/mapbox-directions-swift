import Foundation
import Polyline
import CoreLocation


extension Decodable {
    static internal func from<T: Decodable>(json: String, using encoding: String.Encoding = .utf8) -> T? {
        guard let data = json.data(using: encoding) else { return nil }
        return from(data: data) as T?
    }
    
    static internal func from<T: Decodable>(data: Data) -> T? {
        let decoder = JSONDecoder()
        return try! decoder.decode(T.self, from: data) as T?
    }
}

struct UncertainCodable<T: Codable, U: Codable>: Codable, Equatable {    
    var t: T?
    var u: U?
    
    var options: DirectionsOptions
    
    var value: Codable? {
        return t ?? u
    }
    
    var coordinates: [CLLocationCoordinate2D] {
        if let geo = value as? Geometry {
            return geo.coordinates
        } else if let geo = value as? String {
            return decodePolyline(geo, precision: options.shapeFormat == .polyline6 ? 1e6 : 1e5)!
        } else {
            return []
        }
    }
    
    init(from decoder: Decoder) throws {
        
        guard let options = decoder.userInfo[.options] as? DirectionsOptions else {
            let error: Error = "Directions options object not found."
            throw error
        }
        self.options = options
        
        
        let container = try decoder.singleValueContainer()
        t = try? container.decode(T.self)
        if t == nil {
            u = try? container.decode(U.self)
        }
        
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let t = t {
            try? container.encode(t)
        }
        if let u = u {
            try? container.encode(u)
        }
    }
}

extension String: Error {}


public StepGeometry
// make this a varient transform that's used instead of MBDirectionsResult:38-55, do equatable here, have computed property `shape` that always returns a Polyline no matter the backing data
