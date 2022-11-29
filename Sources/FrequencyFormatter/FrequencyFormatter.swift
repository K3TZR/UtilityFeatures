//
//  FrequencyFormatter.swift
//  
//
//  Created by Douglas Adams on 6/28/22.
//

import Foundation

// --------------------------------------------------------------------------------
// MARK: - Frequency Formatter class implementation
// --------------------------------------------------------------------------------

public final class FrequencyFormatter: NumberFormatter {
  let max: Double = 74.000001
  let min: Double = 1.001
    
    override init() {
      super.init()
      
        // set the parameters
        roundingMode = .ceiling
        allowsFloats = true
    }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  public override func string(for obj: Any?) -> String? {
        // super may provide some functionality
        super.string(for: obj)
        
        // guard that it's a Double
        guard var value = obj as? Double else { return nil }
        
        // allow 4 or 5 digit Khz entries
        if value >= 1_000.0 && value < 10_000.0 { value = value / 1_000 }
      
        guard value <= max else { return adjustPeriods(String(max)) }
        guard value >= min else { return adjustPeriods(String(min)) }
        
        // make a String version, format xx.xxxxxx
        var stringValue = String(format: "%.6f", value)
        
        if stringValue.hasPrefix("0.") { stringValue = String(stringValue.dropFirst(2)) }
        
        // insert the second ".", format xx.xxx.xxx
        stringValue.insert(".", at: stringValue.index(stringValue.endIndex, offsetBy: -3))

        return stringValue
    }
    
  public override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String, range rangep: UnsafeMutablePointer<NSRange>?) throws {
        // return the string to an acceptable Double format (i.e. ##.######)
        let adjustedString = adjustPeriods(string)
        
        // super may provide some functionality
        try super.getObjectValue(obj, for: adjustedString, range: rangep)
        
        // return a Double
        obj?.pointee = (Double(adjustedString) ?? 0.0) as AnyObject
    }
    
    /// Accept a  String in Frequency field format & convert to Double format
    /// - Parameter string:   the String in the Frequency field
    /// Returns:                                    a String in Double / Float format
    ///
    func adjustPeriods(_ string: String) -> String {
        var adjustedString = String(string)
        
        // find the first & last periods
        //    Note: there will always be at least one period
        let firstIndex = adjustedString.firstIndex(of: ".")
        let lastIndex = adjustedString.lastIndex(of: ".")
        let startIndex = adjustedString.startIndex
        
        // if both are found
        if let first = firstIndex, let last = lastIndex {
            
            // format is xx.xxx.xxx, remove 2nd period
            if first < last { adjustedString.remove(at: last) }
            
            // decide if adjustment required
            if first == last {
                // short-circuited action prevents index out of range issue
                if first == adjustedString.startIndex || first == adjustedString.index(startIndex, offsetBy: 1) || first == adjustedString.index(startIndex, offsetBy: 2) {
                    // format is .x  OR x.  OR  xx., do nothing
                    
                } else {
                    // format is xxx.xxx, adjust
                    adjustedString.remove(at: last)
                    adjustedString = "." + adjustedString
                }
            }
        }
        return adjustedString
    }
}
