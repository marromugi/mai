import Foundation

/// The Worker's answer to `GET /account`, as JSON, for an account on Basic paid for until
/// `paidUntil` (milliseconds since 1970), with nothing used.
public func accountAnswer(
  check: Data?, paidUntil: Int64 = 1, lapsed: Bool = false, gracePeriod: Bool = false,
  deletesAt: Int64? = nil
) -> String {
  let hex = check.map { "\"\($0.map { String(format: "%02x", $0) }.joined())\"" } ?? "null"
  let use = { (limit: Int) in #"{"used":0,"limit":\#(limit)}"# }
  return """
    {"plan":"basic","paidUntil":\(paidUntil),"lapsed":\(lapsed),"gracePeriod":\(gracePeriod),\
    "deletesAt":\(deletesAt.map(String.init) ?? "null"),"usage":{\
    "writingsBytes":\(use(100_000_000)),"writings":\(use(10_000)),\
    "photosBytes":\(use(5_000_000_000)),"requests":\(use(3_000)),"lists":\(use(200)),\
    "saves":\(use(500)),"photos":\(use(100))},"ownKeyCheck":\(hex)}
    """
}
