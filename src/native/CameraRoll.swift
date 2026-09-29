import Foundation
import ImageIO

/// Reads the small, documented-by-observation subset of camera metadata needed
/// by Batch Auto Straighten. Unsupported or malformed files deliberately return nil
/// so the caller can fall back to image analysis.
enum CameraRoll {
  private static let maximumPrefixBytes = 1024 * 1024
  private static let canonLevelInfoTag: UInt16 = 0x4059
  private static let nikonShotInfoTag: UInt16 = 0x0091
  private static let ricohLevelInfoTag: UInt16 = 0x022b
  private static let panasonicRollAngleTag: UInt16 = 0x0090
  private static let olympusCameraSettingsTag: UInt16 = 0x2020
  private static let olympusRollAngleTag: UInt16 = 0x0903
  private static let fujiRollAngleTag: UInt16 = 0x144d
  private static let pentaxLevelInfoTag: UInt16 = 0x022b
  private static let appleAccelerationVectorTag: UInt16 = 0x0008

  // Nikon's MakerNote cipher lookup values. These are the unrestricted Nikon
  // metadata values published with dcraw; see NOTICE. The TIFF traversal and
  // bounded Swift implementation below are original to Batch Auto Straighten.
  private static let nikonSerialXlat: [UInt8] = [
    0xc1,0xbf,0x6d,0x0d,0x59,0xc5,0x13,0x9d,0x83,0x61,0x6b,0x4f,0xc7,0x7f,0x3d,0x3d,
    0x53,0x59,0xe3,0xc7,0xe9,0x2f,0x95,0xa7,0x95,0x1f,0xdf,0x7f,0x2b,0x29,0xc7,0x0d,
    0xdf,0x07,0xef,0x71,0x89,0x3d,0x13,0x3d,0x3b,0x13,0xfb,0x0d,0x89,0xc1,0x65,0x1f,
    0xb3,0x0d,0x6b,0x29,0xe3,0xfb,0xef,0xa3,0x6b,0x47,0x7f,0x95,0x35,0xa7,0x47,0x4f,
    0xc7,0xf1,0x59,0x95,0x35,0x11,0x29,0x61,0xf1,0x3d,0xb3,0x2b,0x0d,0x43,0x89,0xc1,
    0x9d,0x9d,0x89,0x65,0xf1,0xe9,0xdf,0xbf,0x3d,0x7f,0x53,0x97,0xe5,0xe9,0x95,0x17,
    0x1d,0x3d,0x8b,0xfb,0xc7,0xe3,0x67,0xa7,0x07,0xf1,0x71,0xa7,0x53,0xb5,0x29,0x89,
    0xe5,0x2b,0xa7,0x17,0x29,0xe9,0x4f,0xc5,0x65,0x6d,0x6b,0xef,0x0d,0x89,0x49,0x2f,
    0xb3,0x43,0x53,0x65,0x1d,0x49,0xa3,0x13,0x89,0x59,0xef,0x6b,0xef,0x65,0x1d,0x0b,
    0x59,0x13,0xe3,0x4f,0x9d,0xb3,0x29,0x43,0x2b,0x07,0x1d,0x95,0x59,0x59,0x47,0xfb,
    0xe5,0xe9,0x61,0x47,0x2f,0x35,0x7f,0x17,0x7f,0xef,0x7f,0x95,0x95,0x71,0xd3,0xa3,
    0x0b,0x71,0xa3,0xad,0x0b,0x3b,0xb5,0xfb,0xa3,0xbf,0x4f,0x83,0x1d,0xad,0xe9,0x2f,
    0x71,0x65,0xa3,0xe5,0x07,0x35,0x3d,0x0d,0xb5,0xe9,0xe5,0x47,0x3b,0x9d,0xef,0x35,
    0xa3,0xbf,0xb3,0xdf,0x53,0xd3,0x97,0x53,0x49,0x71,0x07,0x35,0x61,0x71,0x2f,0x43,
    0x2f,0x11,0xdf,0x17,0x97,0xfb,0x95,0x3b,0x7f,0x6b,0xd3,0x25,0xbf,0xad,0xc7,0xc5,
    0xc5,0xb5,0x8b,0xef,0x2f,0xd3,0x07,0x6b,0x25,0x49,0x95,0x25,0x49,0x6d,0x71,0xc7,
  ]
  private static let nikonCountXlat: [UInt8] = [
    0xa7,0xbc,0xc9,0xad,0x91,0xdf,0x85,0xe5,0xd4,0x78,0xd5,0x17,0x46,0x7c,0x29,0x4c,
    0x4d,0x03,0xe9,0x25,0x68,0x11,0x86,0xb3,0xbd,0xf7,0x6f,0x61,0x22,0xa2,0x26,0x34,
    0x2a,0xbe,0x1e,0x46,0x14,0x68,0x9d,0x44,0x18,0xc2,0x40,0xf4,0x7e,0x5f,0x1b,0xad,
    0x0b,0x94,0xb6,0x67,0xb4,0x0b,0xe1,0xea,0x95,0x9c,0x66,0xdc,0xe7,0x5d,0x6c,0x05,
    0xda,0xd5,0xdf,0x7a,0xef,0xf6,0xdb,0x1f,0x82,0x4c,0xc0,0x68,0x47,0xa1,0xbd,0xee,
    0x39,0x50,0x56,0x4a,0xdd,0xdf,0xa5,0xf8,0xc6,0xda,0xca,0x90,0xca,0x01,0x42,0x9d,
    0x8b,0x0c,0x73,0x43,0x75,0x05,0x94,0xde,0x24,0xb3,0x80,0x34,0xe5,0x2c,0xdc,0x9b,
    0x3f,0xca,0x33,0x45,0xd0,0xdb,0x5f,0xf5,0x52,0xc3,0x21,0xda,0xe2,0x22,0x72,0x6b,
    0x3e,0xd0,0x5b,0xa8,0x87,0x8c,0x06,0x5d,0x0f,0xdd,0x09,0x19,0x93,0xd0,0xb9,0xfc,
    0x8b,0x0f,0x84,0x60,0x33,0x1c,0x9b,0x45,0xf1,0xf0,0xa3,0x94,0x3a,0x12,0x77,0x33,
    0x4d,0x44,0x78,0x28,0x3c,0x9e,0xfd,0x65,0x57,0x16,0x94,0x6b,0xfb,0x59,0xd0,0xc8,
    0x22,0x36,0xdb,0xd2,0x63,0x98,0x43,0xa1,0x04,0x87,0x86,0xf7,0xa6,0x26,0xbb,0xd6,
    0x59,0x4d,0xbf,0x6a,0x2e,0xaa,0x2b,0xef,0xe6,0x78,0xb6,0x4e,0xe0,0x2f,0xdc,0x7c,
    0xbe,0x57,0x19,0x32,0x7e,0x2a,0xd0,0xb8,0xba,0x29,0x00,0x3c,0x52,0x7d,0xa8,0x49,
    0x3b,0x2d,0xeb,0x25,0x49,0xfa,0xa3,0xaa,0x39,0xa7,0xc5,0xa7,0x50,0x11,0x36,0xfb,
    0xc6,0x67,0x4a,0xf5,0xa5,0x12,0x65,0x7e,0xb0,0xdf,0xaf,0x4e,0xb3,0x61,0x7f,0x2f,
  ]

  static func read(path: String) -> (roll: Double, make: String)? {
    guard let data = readPrefix(path: path), data.count >= 16 else {
      return nil
    }
    if data[0] == 0xff, data[1] == 0xd8 {
      return readJPEG(data) ?? readAppleImageIO(path: path)
    }
    if data.matches([0x49, 0x49, 0x2a, 0x00], at: 0)
      || data.matches([0x4d, 0x4d, 0x00, 0x2a], at: 0) {
      return readExifTIFF(data, base: 0, limit: data.count)
        ?? readAppleImageIO(path: path)
    }
    // RW2 and ORF are TIFF-like containers with a vendor magic value in
    // place of 42. Their byte order and first-IFD pointer retain TIFF layout.
    if data.matches([0x49, 0x49, 0x55, 0x00], at: 0)
      || data.matches([0x49, 0x49, 0x52, 0x4f], at: 0)
      || data.matches([0x49, 0x49, 0x52, 0x53], at: 0),
      let firstIFDOffset = data.uint32(at: 4, endian: .little),
      let tiff = TIFFReader(
        data: data,
        base: 0,
        limit: data.count,
        endian: .little,
        firstIFDOffset: firstIFDOffset
      ) {
      return readExifTIFF(data, tiff: tiff)
    }
    if data.matches(Array("FUJIFILMCCD-RAW".utf8), at: 0) {
      return readFujiRAF(data)
    }
    let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
    if pathExtension == "heic" || pathExtension == "heif" {
      return readAppleImageIO(path: path)
    }
    return readCanonCR3(data)
  }

  private static func readPrefix(path: String) -> Data? {
    guard FileManager.default.fileExists(atPath: path),
          let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    else {
      return nil
    }
    defer { handle.closeFile() }
    return try? handle.read(upToCount: maximumPrefixBytes)
  }

  private static func readJPEG(_ data: Data) -> (roll: Double, make: String)? {
    var markerStart = 2
    while markerStart + 4 <= data.count {
      guard data[markerStart] == 0xff else { return nil }
      var markerIndex = markerStart + 1
      while markerIndex < data.count, data[markerIndex] == 0xff {
        markerIndex += 1
      }
      guard markerIndex < data.count else { return nil }
      let marker = data[markerIndex]
      markerStart = markerIndex + 1

      if marker == 0xd9 || marker == 0xda { break }
      if marker == 0x01 || (0xd0...0xd8).contains(marker) { continue }
      guard markerStart + 2 <= data.count,
            let segmentLength = data.uint16BE(at: markerStart),
            segmentLength >= 2
      else {
        return nil
      }
      let payloadStart = markerStart + 2
      let payloadEnd = markerStart + Int(segmentLength)
      guard payloadEnd >= payloadStart, payloadEnd <= data.count else { return nil }

      if marker == 0xe1,
         payloadEnd - payloadStart >= 14,
         data.matches([0x45, 0x78, 0x69, 0x66, 0, 0], at: payloadStart) {
        let tiffBase = payloadStart + 6
        if let result = readExifTIFF(data, base: tiffBase, limit: payloadEnd) {
          return result
        }
      }
      markerStart = payloadEnd
    }
    return nil
  }

  private static func readExifTIFF(
    _ data: Data,
    base: Int,
    limit: Int
  ) -> (roll: Double, make: String)? {
    guard let tiff = TIFFReader(data: data, base: base, limit: limit) else {
      return nil
    }
    return readExifTIFF(data, tiff: tiff)
  }

  private static func readExifTIFF(
    _ data: Data,
    tiff: TIFFReader
  ) -> (roll: Double, make: String)? {
    guard let root = tiff.rootEntries(),
          let makeEntry = root.first(where: { $0.tag == 0x010f }),
          let make = tiff.ascii(makeEntry)
    else {
      return nil
    }
    let upperMake = make.uppercased()
    if upperMake.hasPrefix("CANON") {
      return readCanonExifTIFF(data, tiff: tiff, root: root, make: make)
    }
    if upperMake.hasPrefix("NIKON") {
      return readNikonExifTIFF(data, tiff: tiff, root: root)
    }
    if upperMake.hasPrefix("RICOH") {
      if let modelEntry = root.first(where: { $0.tag == 0x0110 }),
         let model = tiff.ascii(modelEntry)?.uppercased(),
         model.hasPrefix("PENTAX ") {
        // The Pentax reader also validates the AOC/PENTAX MakerNote header.
        return readPentaxExifTIFF(data, tiff: tiff, root: root)
      }
      return readRicohExifTIFF(data, tiff: tiff, root: root)
    }
    if upperMake.hasPrefix("OLYMPUS")
      || upperMake.hasPrefix("OM SYSTEM")
      || upperMake.contains("OM DIGITAL") {
      return readOlympusExifTIFF(data, tiff: tiff, root: root)
    }
    if upperMake.hasPrefix("PANASONIC") || upperMake.hasPrefix("LEICA") {
      return readPanasonicExifTIFF(
        data,
        tiff: tiff,
        root: root,
        make: upperMake.hasPrefix("LEICA") ? "Leica" : "Panasonic"
      )
    }
    if upperMake.hasPrefix("FUJIFILM") {
      return readFujiExifTIFF(data, tiff: tiff, root: root)
    }
    if upperMake.hasPrefix("PENTAX") {
      return readPentaxExifTIFF(data, tiff: tiff, root: root)
    }
    if upperMake.hasPrefix("APPLE") {
      return readAppleExifTIFF(data, tiff: tiff, root: root)
    }
    return nil
  }

  private static func exifMakerEntry(
    tiff: TIFFReader,
    root: [TIFFEntry]
  ) -> TIFFEntry? {
    guard let exifPointer = root.first(where: { $0.tag == 0x8769 }),
          let exif = tiff.entries(relativeOffset: exifPointer.valueOrOffset)
    else {
      return nil
    }
    return exif.first(where: { $0.tag == 0x927c })
  }

  private static func boundedMakerLimit(
    entry: TIFFEntry,
    start: Int,
    tiffLimit: Int
  ) -> Int? {
    guard entry.type == 1 || entry.type == 7, entry.count > 0 else { return nil }
    let declaredEnd = UInt64(start) + UInt64(entry.count)
    guard declaredEnd <= UInt64(Int.max) else { return nil }
    return min(tiffLimit, Int(declaredEnd))
  }

  private static func readPanasonicExifTIFF(
    _ data: Data,
    tiff: TIFFReader,
    root: [TIFFEntry],
    make: String
  ) -> (roll: Double, make: String)? {
    guard let makerEntry = exifMakerEntry(tiff: tiff, root: root),
          let makerStart = tiff.valueStart(makerEntry),
          let makerLimit = boundedMakerLimit(
            entry: makerEntry,
            start: makerStart,
            tiffLimit: tiff.limit
          )
    else {
      return nil
    }

    let ifdStart: Int
    if data.matches(Array("Panasonic\0\0\0".utf8), at: makerStart) {
      ifdStart = makerStart + 12
    } else if make == "Leica",
              data.matches([0x4c, 0x45, 0x49, 0x43, 0x41, 0, 0, 0], at: makerStart) {
      ifdStart = makerStart + 8
    } else if make == "Leica",
              data.matches(Array("LEICA CAMERA AG\0".utf8), at: makerStart) {
      ifdStart = makerStart + 18
    } else {
      return nil
    }

    guard ifdStart >= tiff.base,
          ifdStart < makerLimit,
          ifdStart - tiff.base <= Int(UInt32.max),
          let makerTIFF = TIFFReader(
            data: data,
            base: tiff.base,
            limit: makerLimit,
            endian: tiff.endian,
            firstIFDOffset: UInt32(ifdStart - tiff.base)
          ),
          let maker = makerTIFF.rootEntries(),
          let rollEntry = maker.first(where: { $0.tag == panasonicRollAngleTag }),
          rollEntry.type == 3,
          rollEntry.count == 1,
          let rollOffset = makerTIFF.valueOffset(rollEntry),
          rollOffset >= makerStart,
          rollOffset + 2 <= makerLimit,
          let rawBits = data.uint16(at: rollOffset, endian: makerTIFF.endian)
    else {
      return nil
    }
    let roll = Double(Int16(bitPattern: rawBits)) / 10.0
    guard roll.isFinite, (-180...180).contains(roll) else { return nil }
    return (roll, make)
  }

  private static func readOlympusExifTIFF(
    _ data: Data,
    tiff: TIFFReader,
    root: [TIFFEntry]
  ) -> (roll: Double, make: String)? {
    guard let makerEntry = exifMakerEntry(tiff: tiff, root: root),
          let makerStart = tiff.valueStart(makerEntry),
          let makerLimit = boundedMakerLimit(
            entry: makerEntry,
            start: makerStart,
            tiffLimit: tiff.limit
          )
    else {
      return nil
    }

    let headerSize: Int
    if data.matches(Array("OLYMPUS\0".utf8), at: makerStart) {
      headerSize = 12
    } else if data.matches(Array("OM SYSTEM\0".utf8), at: makerStart) {
      headerSize = 16
    } else {
      return nil
    }
    let byteOrderOffset = makerStart + headerSize - 4
    let makerEndian = data.tiffEndian(at: byteOrderOffset) ?? tiff.endian
    guard let makerTIFF = TIFFReader(
      data: data,
      base: makerStart,
      limit: makerLimit,
      endian: makerEndian,
      firstIFDOffset: UInt32(headerSize)
    ),
    let maker = makerTIFF.rootEntries(),
    let settingsPointer = maker.first(where: { $0.tag == olympusCameraSettingsTag }),
    (settingsPointer.type == 4 || settingsPointer.type == 13),
    settingsPointer.count == 1,
    let settings = makerTIFF.entries(relativeOffset: settingsPointer.valueOrOffset),
    let rollEntry = settings.first(where: { $0.tag == olympusRollAngleTag }),
    rollEntry.type == 8,
    rollEntry.count == 2,
    let rollOffset = makerTIFF.valueOffset(rollEntry),
    let rawBits = data.uint16(at: rollOffset, endian: makerEndian),
    let valid = data.uint16(at: rollOffset + 2, endian: makerEndian),
    valid == 1
    else {
      return nil
    }
    let roll = -Double(Int16(bitPattern: rawBits)) / 10.0
    guard roll.isFinite, (-180...180).contains(roll) else { return nil }
    return (roll, "Olympus")
  }

  private static func readFujiExifTIFF(
    _ data: Data,
    tiff: TIFFReader,
    root: [TIFFEntry]
  ) -> (roll: Double, make: String)? {
    guard let makerEntry = exifMakerEntry(tiff: tiff, root: root),
          let makerStart = tiff.valueStart(makerEntry),
          data.matches(Array("FUJIFILM".utf8), at: makerStart),
          let makerLimit = boundedMakerLimit(
            entry: makerEntry,
            start: makerStart,
            tiffLimit: tiff.limit
          ),
          let firstIFDOffset = data.uint32(at: makerStart + 8, endian: .little),
          let makerTIFF = TIFFReader(
            data: data,
            base: makerStart,
            limit: makerLimit,
            endian: .little,
            firstIFDOffset: firstIFDOffset
          ),
          let maker = makerTIFF.rootEntries(),
          let rollEntry = maker.first(where: { $0.tag == fujiRollAngleTag }),
          let roll = makerTIFF.signedRational(rollEntry),
          roll.isFinite,
          abs(roll) > 1e-9,
          (-180...180).contains(roll)
    else {
      return nil
    }
    return (roll, "Fujifilm")
  }

  private static func readFujiRAF(_ data: Data) -> (roll: Double, make: String)? {
    guard data.count >= 0x5c,
          let jpegOffset = data.uint32BE(at: 0x54),
          let jpegLength = data.uint32BE(at: 0x58),
          jpegOffset > 0,
          jpegLength > 0,
          UInt64(jpegOffset) < UInt64(data.count),
          UInt64(jpegOffset) + UInt64(jpegLength) <= UInt64(Int.max)
    else {
      return nil
    }
    // The prefix may end before the full RAF preview. JPEG parsing only needs
    // its leading Exif APP1 segment, so keep the same global 1 MiB bound.
    let declaredEnd = Int(UInt64(jpegOffset) + UInt64(jpegLength))
    let jpegEnd = min(data.count, declaredEnd)
    guard jpegEnd > Int(jpegOffset) else { return nil }
    return readJPEG(data.subdata(in: Int(jpegOffset)..<jpegEnd))
  }

  private static func readPentaxExifTIFF(
    _ data: Data,
    tiff: TIFFReader,
    root: [TIFFEntry]
  ) -> (roll: Double, make: String)? {
    let makerEntry = root.first(where: { $0.tag == 0xc634 })
      ?? exifMakerEntry(tiff: tiff, root: root)
    guard let makerEntry,
          let modelEntry = root.first(where: { $0.tag == 0x0110 }),
          let model = tiff.ascii(modelEntry).map({ $0.uppercased() }),
          let makerStart = tiff.valueStart(makerEntry),
          let makerLimit = boundedMakerLimit(
            entry: makerEntry,
            start: makerStart,
            tiffLimit: tiff.limit
          )
    else {
      return nil
    }

    let makerTIFF: TIFFReader?
    if data.matches(Array("AOC\0".utf8), at: makerStart),
       let endian = data.tiffEndian(at: makerStart + 4),
       makerStart + 6 >= tiff.base,
       makerStart + 6 - tiff.base <= Int(UInt32.max) {
      makerTIFF = TIFFReader(
        data: data,
        base: tiff.base,
        limit: makerLimit,
        endian: endian,
        firstIFDOffset: UInt32(makerStart + 6 - tiff.base)
      )
    } else if data.matches(Array("PENTAX \0".utf8), at: makerStart),
              let endian = data.tiffEndian(at: makerStart + 8) {
      makerTIFF = TIFFReader(
        data: data,
        base: makerStart,
        limit: makerLimit,
        endian: endian,
        firstIFDOffset: 10
      )
    } else {
      makerTIFF = nil
    }

    guard let makerTIFF,
          let maker = makerTIFF.rootEntries(),
          let levelEntry = maker.first(where: { $0.tag == pentaxLevelInfoTag }),
          (levelEntry.type == 1 || levelEntry.type == 7),
          let levelStart = makerTIFF.valueOffset(levelEntry),
          levelStart >= makerStart
    else {
      return nil
    }

    let roll: Double
    if model.contains("K-3 MARK III") {
      guard levelEntry.count >= 5,
            levelStart + 5 <= makerLimit,
            let rawBits = data.uint16(at: levelStart + 3, endian: makerTIFF.endian)
      else {
        return nil
      }
      roll = -Double(Int16(bitPattern: rawBits)) / 2.0
    } else {
      guard levelEntry.count >= 3, levelStart + 3 <= makerLimit else { return nil }
      roll = -Double(Int8(bitPattern: data[levelStart + 1])) / 2.0
    }
    guard roll.isFinite, (-180...180).contains(roll) else { return nil }
    return (roll, "Pentax")
  }

  private static func readAppleExifTIFF(
    _ data: Data,
    tiff: TIFFReader,
    root: [TIFFEntry]
  ) -> (roll: Double, make: String)? {
    guard let orientationEntry = root.first(where: { $0.tag == 0x0112 }),
          let orientation = tiff.uint16(orientationEntry),
          let makerEntry = exifMakerEntry(tiff: tiff, root: root),
          let makerStart = tiff.valueStart(makerEntry),
          data.matches(Array("Apple iOS\0".utf8), at: makerStart),
          let makerLimit = boundedMakerLimit(
            entry: makerEntry,
            start: makerStart,
            tiffLimit: tiff.limit
          ),
          let makerEndian = data.tiffEndian(at: makerStart + 12),
          let makerTIFF = TIFFReader(
            data: data,
            base: makerStart,
            limit: makerLimit,
            endian: makerEndian,
            firstIFDOffset: 14
          ),
          let maker = makerTIFF.rootEntries(),
          let vectorEntry = maker.first(where: { $0.tag == appleAccelerationVectorTag }),
          let vector = makerTIFF.signedRationals(vectorEntry, count: 3),
          let roll = appleRoll(vector: vector, orientation: Int(orientation))
    else {
      return nil
    }
    return (roll, "Apple")
  }

  private static func readAppleImageIO(path: String) -> (roll: Double, make: String)? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
          let tiff = properties[kCGImagePropertyTIFFDictionary] as? NSDictionary,
          let make = tiff[kCGImagePropertyTIFFMake] as? String,
          make.uppercased().hasPrefix("APPLE"),
          let maker = properties[kCGImagePropertyMakerAppleDictionary] as? NSDictionary,
          let rawVector = maker["8"] as? [Any],
          rawVector.count == 3,
          let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
    else {
      return nil
    }

    let vector = rawVector.compactMap { value -> Double? in
      if let number = value as? NSNumber { return number.doubleValue }
      if let string = value as? String { return Double(string) }
      return nil
    }
    guard vector.count == 3,
          let roll = appleRoll(vector: vector, orientation: orientation)
    else {
      return nil
    }
    return (roll, "Apple")
  }

  private static func appleRoll(vector: [Double], orientation: Int) -> Double? {
    guard vector.count == 3,
          vector.allSatisfy({ $0.isFinite })
    else {
      return nil
    }
    let x = vector[0]
    let y = vector[1]
    let z = vector[2]
    let magnitude = sqrt(x * x + y * y + z * z)
    let screenProjection = sqrt(x * x + y * y)
    guard (0.75...1.25).contains(magnitude),
          screenProjection / magnitude >= 0.5
    else {
      return nil
    }

    let orientationCorrection: Double
    switch orientation {
    case 1: orientationCorrection = 0
    case 3: orientationCorrection = 180
    case 6: orientationCorrection = 90
    case 8: orientationCorrection = -90
    default: return nil
    }

    var roll = atan2(y, -x) * 180.0 / Double.pi + orientationCorrection
    while roll > 180 { roll -= 360 }
    while roll <= -180 { roll += 360 }
    guard roll.isFinite, abs(roll) <= 45 else { return nil }
    return roll
  }

  private static func readCanonExifTIFF(
    _ data: Data,
    tiff: TIFFReader,
    root: [TIFFEntry],
    make: String
  ) -> (roll: Double, make: String)? {
    guard let exifPointer = root.first(where: { $0.tag == 0x8769 }),
          let exif = tiff.entries(relativeOffset: exifPointer.valueOrOffset),
          let makerEntry = exif.first(where: { $0.tag == 0x927c }),
          makerEntry.type == 7,
          let makerStart = tiff.valueOffset(makerEntry),
          let makerLimit = boundedMakerLimit(entry: makerEntry, start: makerStart, tiffLimit: tiff.limit),
          let bounded = TIFFReader(data: data, base: tiff.base, limit: makerLimit,
            endian: tiff.endian, firstIFDOffset: 0)
    else {
      return nil
    }

    let ifdStart: Int
    if data.matches([0x43, 0x61, 0x6e, 0x6f, 0x6e, 0, 0, 0], at: makerStart) {
      ifdStart = makerStart + 8
    } else {
      ifdStart = makerStart
    }
    guard let maker = bounded.entries(absoluteOffset: ifdStart),
          let level = maker.first(where: { $0.tag == canonLevelInfoTag }),
          let levelStart = bounded.valueOffset(level), levelStart >= makerStart,
          let roll = bounded.roll(from: maker, levelInfoTag: canonLevelInfoTag)
    else {
      return nil
    }
    return (roll, make)
  }

  private static func readNikonExifTIFF(
    _ data: Data,
    tiff: TIFFReader,
    root: [TIFFEntry]
  ) -> (roll: Double, make: String)? {
    guard let modelEntry = root.first(where: { $0.tag == 0x0110 }),
          let model = tiff.ascii(modelEntry),
          let exifPointer = root.first(where: { $0.tag == 0x8769 }),
          let exif = tiff.entries(relativeOffset: exifPointer.valueOrOffset),
          let makerEntry = exif.first(where: { $0.tag == 0x927c }),
          makerEntry.type == 7,
          makerEntry.count >= 18,
          let makerStart = tiff.valueOffset(makerEntry),
          data.matches([0x4e, 0x69, 0x6b, 0x6f, 0x6e, 0x00, 0x02], at: makerStart),
          UInt64(makerStart) + UInt64(makerEntry.count) <= UInt64(tiff.limit)
    else {
      return nil
    }

    let makerEnd = makerStart + Int(makerEntry.count)
    let nestedBase = makerStart + 10
    guard let makerTIFF = TIFFReader(data: data, base: nestedBase, limit: makerEnd),
          let maker = makerTIFF.rootEntries(),
          let serialEntry = maker.first(where: { $0.tag == 0x001d }),
          let serialText = makerTIFF.ascii(serialEntry),
          !serialText.isEmpty,
          serialText.allSatisfy({ $0.isNumber }),
          let serial = UInt64(serialText),
          let shutterEntry = maker.first(where: { $0.tag == 0x00a7 }),
          let shutterCount = makerTIFF.uint32(shutterEntry),
          let shotEntry = maker.first(where: { $0.tag == nikonShotInfoTag }),
          shotEntry.type == 7,
          let shotStart = makerTIFF.valueOffset(shotEntry),
          UInt64(shotStart) + UInt64(shotEntry.count) <= UInt64(makerEnd)
    else {
      return nil
    }

    if let modeEntry = maker.first(where: { $0.tag == 0x0034 }),
       let mode = makerTIFF.uint16(modeEntry),
       mode == 96 {
      return nil
    }

    let shotLength = Int(shotEntry.count)
    guard shotLength >= 4 else { return nil }
    var shot = Array(data[shotStart..<(shotStart + shotLength)])
    let version = String(bytes: shot[0..<4], encoding: .ascii) ?? ""
    guard let orientationPointerOffset = nikonOrientationPointerOffset(
      version: version,
      model: model
    ) else {
      return nil
    }

    decryptNikonShotInfo(&shot, serial: serial, shutterCount: shutterCount)
    guard let numberOffsets = shot.uint32LE(at: 0x24),
          orientationPointerOffset >= 0x28,
          (orientationPointerOffset - 0x28) / 4 < Int(numberOffsets),
          let orientationOffset = shot.uint32LE(at: orientationPointerOffset),
          orientationOffset > 0,
          UInt64(orientationOffset) + 4 <= UInt64(shot.count),
          let rollBits = shot.uint32LE(at: Int(orientationOffset)),
          rollBits <= 360 * 65_536
    else {
      return nil
    }

    var roll = Double(rollBits) / 65_536.0
    if roll > 180 { roll -= 360 }
    guard roll.isFinite, (-180...180).contains(roll) else { return nil }
    return (roll, "Nikon")
  }

  private static func nikonOrientationPointerOffset(version: String, model: String) -> Int? {
    switch version {
    case "0805", "0806":
      return 0x84 // Z9 / Z8
    case "0809", "0810", "0811":
      return 0x88 // Z6III / Z50II / Z5II
    case "0800", "0801", "0802", "0803", "0804", "0807":
      return 0x98 // Z6/Z7/Z50/Z5/Z6II/Z7II/Zfc/Z30
    case "0808":
      return model.uppercased().contains("NIKON Z F") ? 0x88 : nil
    default:
      return nil
    }
  }

  private static func decryptNikonShotInfo(
    _ bytes: inout [UInt8],
    serial: UInt64,
    shutterCount: UInt32
  ) {
    guard bytes.count > 4 else { return }
    let serialIndex = Int(serial & 0xff)
    let countKey = UInt8(truncatingIfNeeded: shutterCount)
      ^ UInt8(truncatingIfNeeded: shutterCount >> 8)
      ^ UInt8(truncatingIfNeeded: shutterCount >> 16)
      ^ UInt8(truncatingIfNeeded: shutterCount >> 24)
    let ci = nikonSerialXlat[serialIndex]
    var cj = nikonCountXlat[Int(countKey)]
    var ck: UInt8 = 0x60
    for index in 4..<bytes.count {
      cj = cj &+ (ci &* ck)
      ck = ck &+ 1
      bytes[index] ^= cj
    }
  }

  private static func readRicohExifTIFF(
    _ data: Data,
    tiff: TIFFReader,
    root: [TIFFEntry]
  ) -> (roll: Double, make: String)? {
    let makerEntry: TIFFEntry?
    if let privateData = root.first(where: { $0.tag == 0xc634 }) {
      makerEntry = privateData
    } else if let exifPointer = root.first(where: { $0.tag == 0x8769 }),
              let exif = tiff.entries(relativeOffset: exifPointer.valueOrOffset) {
      makerEntry = exif.first(where: { $0.tag == 0x927c })
    } else {
      makerEntry = nil
    }

    guard let modelEntry = root.first(where: { $0.tag == 0x0110 }),
          let model = tiff.ascii(modelEntry).map({ $0.uppercased() }),
          model.hasPrefix("RICOH GR III") || model.hasPrefix("RICOH GR IV"),
          let makerEntry,
          makerEntry.type == 1 || makerEntry.type == 7,
          makerEntry.count >= 26,
          let makerStart = tiff.valueOffset(makerEntry),
          UInt64(makerStart) + UInt64(makerEntry.count) <= UInt64(tiff.limit),
          data.matches([0x52, 0x49, 0x43, 0x4f, 0x48, 0, 0x49, 0x49], at: makerStart)
    else {
      return nil
    }

    let makerEnd = makerStart + Int(makerEntry.count)
    guard let makerTIFF = TIFFReader(
      data: data,
      base: makerStart,
      limit: makerEnd,
      endian: .little,
      firstIFDOffset: 8
    ),
    let maker = makerTIFF.rootEntries(),
    let levelEntry = maker.first(where: { $0.tag == ricohLevelInfoTag }),
    levelEntry.type == 7,
    levelEntry.count >= 3,
    let levelStart = makerTIFF.valueOffset(levelEntry)
    else {
      return nil
    }

    let raw = Int8(bitPattern: data[levelStart + 1])
    return (-Double(raw) / 2.0, "Ricoh")
  }

  private static func readCanonCR3(_ data: Data) -> (roll: Double, make: String)? {
    guard data.count >= 20,
          data.matches([0x66, 0x74, 0x79, 0x70], at: 4),
          data.matches([0x63, 0x72, 0x78, 0x20], at: 8)
    else {
      return nil
    }

    let boxType = Data([0x43, 0x4d, 0x54, 0x33]) // CMT3
    var searchStart = 8
    while searchStart + boxType.count <= data.count,
          let match = data.range(of: boxType, in: searchStart..<data.count) {
      let typeStart = match.lowerBound
      defer { searchStart = match.upperBound }
      guard typeStart >= 4,
            let size = data.uint32BE(at: typeStart - 4),
            size >= 16,
            UInt64(typeStart - 4) + UInt64(size) <= UInt64(data.count)
      else {
        continue
      }
      let payloadStart = typeStart + 4
      let boxEnd = typeStart - 4 + Int(size)
      guard let tiff = TIFFReader(data: data, base: payloadStart, limit: boxEnd),
            let root = tiff.rootEntries(),
            let roll = tiff.roll(from: root, levelInfoTag: canonLevelInfoTag)
      else {
        continue
      }
      return (roll, "Canon")
    }
    return nil
  }
}

private enum TIFFEndian {
  case little
  case big
}

private struct TIFFEntry {
  let tag: UInt16
  let type: UInt16
  let count: UInt32
  let valueOrOffset: UInt32
  let inlineValueOffset: Int
}

private struct TIFFReader {
  let data: Data
  let base: Int
  let limit: Int
  let endian: TIFFEndian
  let firstIFDOffset: UInt32

  init?(data: Data, base: Int, limit: Int) {
    guard base >= 0, limit <= data.count, limit - base >= 8 else { return nil }
    let endian: TIFFEndian
    if data.matches([0x49, 0x49], at: base) {
      endian = .little
    } else if data.matches([0x4d, 0x4d], at: base) {
      endian = .big
    } else {
      return nil
    }
    guard data.uint16(at: base + 2, endian: endian) == 42,
          let firstIFDOffset = data.uint32(at: base + 4, endian: endian)
    else {
      return nil
    }
    self.data = data
    self.base = base
    self.limit = limit
    self.endian = endian
    self.firstIFDOffset = firstIFDOffset
  }

  init?(
    data: Data,
    base: Int,
    limit: Int,
    endian: TIFFEndian,
    firstIFDOffset: UInt32
  ) {
    guard base >= 0, limit <= data.count, base <= limit,
          UInt64(base) + UInt64(firstIFDOffset) <= UInt64(limit)
    else {
      return nil
    }
    self.data = data
    self.base = base
    self.limit = limit
    self.endian = endian
    self.firstIFDOffset = firstIFDOffset
  }

  func rootEntries() -> [TIFFEntry]? {
    entries(relativeOffset: firstIFDOffset)
  }

  func entries(relativeOffset: UInt32) -> [TIFFEntry]? {
    let absolute = UInt64(base) + UInt64(relativeOffset)
    guard absolute <= UInt64(Int.max) else { return nil }
    return entries(absoluteOffset: Int(absolute))
  }

  func entries(absoluteOffset: Int) -> [TIFFEntry]? {
    guard contains(absoluteOffset, length: 2),
          let count = data.uint16(at: absoluteOffset, endian: endian),
          count <= 4096
    else {
      return nil
    }
    let entriesStart = absoluteOffset + 2
    let entriesBytes = Int(count) * 12
    guard contains(entriesStart, length: entriesBytes + 4) else { return nil }

    var result: [TIFFEntry] = []
    result.reserveCapacity(Int(count))
    for index in 0..<Int(count) {
      let offset = entriesStart + index * 12
      guard let tag = data.uint16(at: offset, endian: endian),
            let type = data.uint16(at: offset + 2, endian: endian),
            let valueCount = data.uint32(at: offset + 4, endian: endian),
            let valueOrOffset = data.uint32(at: offset + 8, endian: endian)
      else {
        return nil
      }
      result.append(TIFFEntry(
        tag: tag,
        type: type,
        count: valueCount,
        valueOrOffset: valueOrOffset,
        inlineValueOffset: offset + 8
      ))
    }
    return result
  }

  func ascii(_ entry: TIFFEntry) -> String? {
    guard entry.type == 2, entry.count > 0,
          let offset = valueOffset(entry),
          let length = byteCount(entry),
          contains(offset, length: length)
    else {
      return nil
    }
    let bytes = data[offset..<(offset + length)]
    let textBytes = bytes.prefix { $0 != 0 }
    return String(bytes: textBytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
  }

  func roll(from entries: [TIFFEntry], levelInfoTag: UInt16) -> Double? {
    guard let level = entries.first(where: { $0.tag == levelInfoTag }),
          (level.type == 4 || level.type == 9),
          level.count >= 5,
          let offset = valueOffset(level),
          let length = byteCount(level),
          contains(offset, length: length),
          let rawBits = data.uint32(at: offset + 4 * 4, endian: endian)
    else {
      return nil
    }

    var tenths: Int64
    if level.type == 9 {
      tenths = Int64(Int32(bitPattern: rawBits))
      guard (-1800...3599).contains(tenths) else { return nil }
    } else {
      guard rawBits <= 3599 else { return nil }
      tenths = Int64(rawBits)
    }
    if tenths > 1800 { tenths -= 3600 }
    guard (-1800...1800).contains(tenths) else { return nil }
    return -Double(tenths) / 10.0
  }

  func valueOffset(_ entry: TIFFEntry) -> Int? {
    guard let length = byteCount(entry) else { return nil }
    if length <= 4 {
      return contains(entry.inlineValueOffset, length: length) ? entry.inlineValueOffset : nil
    }
    let absolute = UInt64(base) + UInt64(entry.valueOrOffset)
    guard absolute <= UInt64(Int.max) else { return nil }
    let offset = Int(absolute)
    return contains(offset, length: length) ? offset : nil
  }

  /// Returns the beginning of a value even when the declared value extends
  /// beyond the bounded prefix. This is used only to enter large MakerNotes;
  /// every nested directory and scalar read still performs its own bounds check.
  func valueStart(_ entry: TIFFEntry) -> Int? {
    guard entry.count > 0, let length = byteCount(entry) else { return nil }
    if length <= 4 {
      return contains(entry.inlineValueOffset, length: length) ? entry.inlineValueOffset : nil
    }
    let absolute = UInt64(base) + UInt64(entry.valueOrOffset)
    guard absolute <= UInt64(Int.max) else { return nil }
    let offset = Int(absolute)
    return contains(offset, length: 1) ? offset : nil
  }

  func signedRational(_ entry: TIFFEntry) -> Double? {
    guard entry.type == 10,
          entry.count == 1,
          let offset = valueOffset(entry),
          let numeratorBits = data.uint32(at: offset, endian: endian),
          let denominatorBits = data.uint32(at: offset + 4, endian: endian)
    else {
      return nil
    }
    let numerator = Int32(bitPattern: numeratorBits)
    let denominator = Int32(bitPattern: denominatorBits)
    guard denominator != 0 else { return nil }
    return Double(numerator) / Double(denominator)
  }

  func signedRationals(_ entry: TIFFEntry, count: Int) -> [Double]? {
    guard count > 0,
          entry.type == 10,
          entry.count == UInt32(count),
          let offset = valueOffset(entry)
    else {
      return nil
    }
    var values: [Double] = []
    values.reserveCapacity(count)
    for index in 0..<count {
      let itemOffset = offset + index * 8
      guard let numeratorBits = data.uint32(at: itemOffset, endian: endian),
            let denominatorBits = data.uint32(at: itemOffset + 4, endian: endian)
      else {
        return nil
      }
      let numerator = Int32(bitPattern: numeratorBits)
      let denominator = Int32(bitPattern: denominatorBits)
      guard denominator != 0 else { return nil }
      values.append(Double(numerator) / Double(denominator))
    }
    return values
  }

  func uint16(_ entry: TIFFEntry) -> UInt16? {
    guard entry.type == 3, entry.count == 1,
          let offset = valueOffset(entry)
    else {
      return nil
    }
    return data.uint16(at: offset, endian: endian)
  }

  func uint32(_ entry: TIFFEntry) -> UInt32? {
    guard (entry.type == 4 || entry.type == 9), entry.count == 1,
          let offset = valueOffset(entry)
    else {
      return nil
    }
    return data.uint32(at: offset, endian: endian)
  }

  private func byteCount(_ entry: TIFFEntry) -> Int? {
    let width: UInt64
    switch entry.type {
    case 1, 2, 6, 7: width = 1
    case 3, 8: width = 2
    case 4, 9, 11: width = 4
    case 5, 10, 12: width = 8
    default: return nil
    }
    let size = UInt64(entry.count) * width
    guard size <= UInt64(Int.max) else { return nil }
    return Int(size)
  }

  private func contains(_ offset: Int, length: Int) -> Bool {
    offset >= base && length >= 0 && offset <= limit && length <= limit - offset
  }
}

private extension Data {
  func tiffEndian(at offset: Int) -> TIFFEndian? {
    if matches([0x49, 0x49], at: offset) { return .little }
    if matches([0x4d, 0x4d], at: offset) { return .big }
    return nil
  }

  func matches(_ bytes: [UInt8], at offset: Int) -> Bool {
    guard offset >= 0, offset <= count, bytes.count <= count - offset else {
      return false
    }
    for (index, byte) in bytes.enumerated() where self[offset + index] != byte {
      return false
    }
    return true
  }

  func uint16BE(at offset: Int) -> UInt16? {
    uint16(at: offset, endian: .big)
  }

  func uint32BE(at offset: Int) -> UInt32? {
    uint32(at: offset, endian: .big)
  }

  func uint16(at offset: Int, endian: TIFFEndian) -> UInt16? {
    guard offset >= 0, offset + 2 <= count else { return nil }
    let a = UInt16(self[offset])
    let b = UInt16(self[offset + 1])
    return endian == .little ? a | (b << 8) : (a << 8) | b
  }

  func uint32(at offset: Int, endian: TIFFEndian) -> UInt32? {
    guard offset >= 0, offset + 4 <= count else { return nil }
    let a = UInt32(self[offset])
    let b = UInt32(self[offset + 1])
    let c = UInt32(self[offset + 2])
    let d = UInt32(self[offset + 3])
    if endian == .little {
      return a | (b << 8) | (c << 16) | (d << 24)
    }
    return (a << 24) | (b << 16) | (c << 8) | d
  }
}

private extension Array where Element == UInt8 {
  func uint32LE(at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= count else { return nil }
    return UInt32(self[offset])
      | (UInt32(self[offset + 1]) << 8)
      | (UInt32(self[offset + 2]) << 16)
      | (UInt32(self[offset + 3]) << 24)
  }
}
