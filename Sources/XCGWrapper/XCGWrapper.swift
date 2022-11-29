//
//  XCGWrapper.swift
//  UtilityComponents/XCGWrapper
//
//  Created by Douglas Adams on 12/20/21.
//

import Foundation
import Combine
import XCGLogger
import ObjcExceptionBridging

import Shared

public final class XCGWrapper: Equatable {
  // ----------------------------------------------------------------------------
  // MARK: - Internal properties
  
  public let log: XCGLogger
  
  // ----------------------------------------------------------------------------
  // MARK: - Private properties
    
  private var _defaultFolder: String!
  private var _defaultLogUrl: URL!
  private var _log: XCGLogger!

  private let kMaxLogFiles: UInt8  = 10
  private let kMaxTime: TimeInterval = 60 * 60 // 1 Hour
  
  private var _cancellable: AnyCancellable?

  public static func == (lhs: XCGWrapper, rhs: XCGWrapper) -> Bool {
    lhs === rhs
  }

  // ----------------------------------------------------------------------------
  // MARK: - Singleton
  
  public init(logLevel: LogLevel = .debug) {

    var xcgLogLevel: XCGLogger.Level
    switch logLevel {
    case .debug:
      xcgLogLevel = XCGLogger.Level.debug
    case .info:
      xcgLogLevel = XCGLogger.Level.info
    case .warning:
      xcgLogLevel = XCGLogger.Level.warning
    case .error:
      xcgLogLevel = XCGLogger.Level.error
    }
    
    let info = getBundleInfo()
    
    log = XCGLogger(identifier: info.appName, includeDefaultDestinations: false)
    
    let defaultLogName = info.appName + ".log"
    _defaultFolder = URL.appSupport.path + "/" + info.domain + "." + info.appName  + "/Logs"

#if DEBUG
    // for DEBUG only
    // Create a destination for the system console log (via NSLog)
    let systemDestination = AppleSystemLogDestination(identifier: info.appName + ".systemDestination")
    
    // Optionally set some configuration options
    systemDestination.outputLevel           = xcgLogLevel
    systemDestination.showFileName          = false
    systemDestination.showFunctionName      = false
    systemDestination.showLevel             = true
    systemDestination.showLineNumber        = false
    systemDestination.showLogIdentifier     = false
    systemDestination.showThreadName        = false
    
    // Add the destination to the logger
    log.add(destination: systemDestination)
#endif
    
    // Get / Create a file log destination
    if let logs = setupLogFolder(info) {
      let fileDestination = AutoRotatingFileDestination(writeToFile: logs.appendingPathComponent(defaultLogName),
                                                        identifier: info.appName + ".autoRotatingFileDestination",
                                                        shouldAppend: true,
                                                        appendMarker: "- - - - - App was restarted - - - - -")
      
      // Optionally set some configuration options
      fileDestination.outputLevel             = xcgLogLevel
      fileDestination.showDate                = true
      fileDestination.showFileName            = false
      fileDestination.showFunctionName        = false
      fileDestination.showLevel               = true
      fileDestination.showLineNumber          = false
      fileDestination.showLogIdentifier       = false
      fileDestination.showThreadName          = false
      fileDestination.targetMaxLogFiles       = kMaxLogFiles
      fileDestination.targetMaxTimeInterval   = kMaxTime
      
      // Process this destination in the background
      fileDestination.logQueue = XCGLogger.logQueue
      
      // Add the destination to the logger
      log.add(destination: fileDestination)
      
      // Add basic app info, version info etc, to the start of the logs
      log.logAppDetails()
      
      // format the date (only effects the file logging)
      let dateFormatter = DateFormatter()
      dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss:SSS"
      dateFormatter.locale = Locale.current
      log.dateFormatter = dateFormatter
      
      _defaultLogUrl = URL(fileURLWithPath: _defaultFolder + "/" + defaultLogName)

      // subscribe to Log requests
      Task {
        for await entry in logEntries {
          // Log Handler to support XCGLogger
          switch entry.level {
            
          case .debug:    log.debug(entry.msg, functionName: entry.function, fileName: entry.file, lineNumber: entry.line)
          case .info:     log.info(entry.msg, functionName: entry.function, fileName: entry.file, lineNumber: entry.line)
          case .warning:  log.warning(entry.msg, functionName: entry.function, fileName: entry.file, lineNumber: entry.line)
          case .error:    log.error(entry.msg, functionName: entry.function, fileName: entry.file, lineNumber: entry.line)
          }
        }
      }

    } else {
      fatalError("Logging failure:, unable to find / create Log folder")
    }
  }
}
