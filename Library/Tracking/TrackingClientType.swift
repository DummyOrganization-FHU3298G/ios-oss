public protocol TrackingClientType {
  /**
   Tracks an event in our analytics system.

   - parameter event:      Name of the event.
   - parameter properties: Dictionary of properties associated with event.
   */
  func track(name: String, properties: [String: Any]?)
}
