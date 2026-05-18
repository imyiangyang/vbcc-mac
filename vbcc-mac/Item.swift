//
//  Item.swift
//  vbcc-mac
//
//  Created by yang on 2026/5/19.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
