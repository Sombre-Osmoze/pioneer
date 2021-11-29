//
//  Dictionary+SafeOperation.swift
//  Pioneer
//
//  Created by d-exclaimation on 11:38 PM.
//  Copyright © 2021 d-exclaimation. All rights reserved.
//

import Foundation

extension Dictionary {
    mutating func update(_ key: Key, with value: Value) {
        self[key] = value
    }

    mutating func delete(_ key: Key) {
        removeValue(forKey: key)
    }

    mutating func getOrElse(_ key: Key, or fallback: () -> Value) -> Value {
        self[key] ?? fallback()
    }
}