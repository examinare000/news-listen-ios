//
//  GenerationQuota+Domain.swift
//  NewsListenApp
//
//  通信の `GenerationQuota` を domain の `GenerationAllowance` へ写す adapter。
//

import Foundation

extension GenerationQuota {
    /// 負の値の応答は残り回数が無いものとして nil。`resetAt` は使わない。
    func toAllowance() -> GenerationAllowance? {
        GenerationAllowance(limit: limit, used: used, remaining: remaining)
    }
}
