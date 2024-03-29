//
//  SecureStore.swift
//  UtilityFeatures/SecureStorage
//
//  Created by Douglas Adams on 9/5/20.
//  Copyright © 2020-2021 Douglas Adams. All rights reserved.
//

import Foundation

final public class SecureStore : Equatable {
  public static func == (lhs: SecureStore, rhs: SecureStore) -> Bool {
    return lhs === rhs
  }
  
  // ----------------------------------------------------------------------------
  // MARK: - Private properties
  
  private var _wrapper : KeychainWrapper
  
  // ----------------------------------------------------------------------------
  // MARK: - Initialization
  
  public init(service: String) {
    _wrapper = KeychainWrapper(serviceName: service)
  }
  
  // ----------------------------------------------------------------------------
  // MARK: - Public methods
  
  public func set(account: String?, data: String) -> Bool {
    guard account != nil else { return false }
    return _wrapper.set(data, forKey: account!)
  }
  
  public func get(account: String?) -> String? {
    guard account != nil else { return nil }
    return _wrapper.string(forKey: account!)
  }
  
  public func delete(account: String?) -> Bool{
    guard account != nil else { return false }
    return _wrapper.removeObject(forKey: account!)
  }
}
