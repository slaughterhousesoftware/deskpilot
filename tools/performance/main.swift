import Foundation
var bytes = Data()
var minute = 0
var up = false
while bytes.count < 8192 {
    minute += 20
    for kind: UInt8 in [0x59 | (up ? 1 : 0), 0x26 + (up ? 15 : 0), 0x5C | (up ? 1 : 0)] {
        bytes.append(UInt8(minute % 256)); bytes.append(kind)
    }
    if minute % 180 == 0 { bytes.append(contentsOf: [UInt8(minute % 256),0x50,UInt8((minute+7)%256),0x51]) }
    up.toggle()
}
bytes = bytes.prefix(8192)
let now = Date(timeIntervalSince1970: 1_800_000_000)
var events = HistoryDecoder.dateEntries(HistoryDecoder.decodeEntries(bytes), minutesSincePowerOn: 70_000, now: now)
events.append(HistoryEvent(byteOffset: -1, date: now.addingTimeInterval(-30), kind: .move(toStanding: true)))
events.sort { $0.date < $1.date }
let cruise = CruiseSlot(standingSeconds: 1200, sittingSeconds: 1200)
let reference = DayRollup.compute(events: events, now: now, dayStart: now.addingTimeInterval(-36000), cruise: cruise, paused: false, standingThresholdInches: 34)
print("Fixture atDeskSeconds", reference.atDeskSeconds, "stands", reference.stands)
var checksum = 0.0
for _ in 0..<1000 { checksum += DayRollup.compute(events: events, now: now, dayStart: now.addingTimeInterval(-36000), cruise: cruise, paused: false, standingThresholdInches: 34).atDeskSeconds }
for batch in 0..<5 {
 let start = DispatchTime.now().uptimeNanoseconds
 for _ in 0..<10000 { checksum += DayRollup.compute(events: events, now: now, dayStart: now.addingTimeInterval(-36000), cruise: cruise, paused: false, standingThresholdInches: 34).atDeskSeconds }
 let us = Double(DispatchTime.now().uptimeNanoseconds-start)/10000/1000
 print("Swift rollup-only batch",batch,"µs:",us)
}
print("Events",events.count,"checksum",checksum)
