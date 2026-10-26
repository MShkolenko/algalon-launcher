// Common release-client layout and validated Blizzard key-table data.
import Foundation

enum C {
    // The official product folder and our byte-identical sibling copy, inside the same "World of Warcraft" folder.
    static let officialProduct = "_forever_"
    static let appName = "World of Warcraft.app"
    static let binaryInApp = "Contents/MacOS/World of Warcraft"

    // Runtime region group selected for the private realm.
    static let group = 8

    // The 12 stock Blizzard region-group keys, in order (ids 1..12), and their flag bytes.
    static let knownHex: [String] = [
        "9B0671C815DFF513BFD4A2B26AE1F84EC9106841B2FB620DB65F6ADE7C21AD06",
        "112451B9843C2799E4750AA3D9B9AFABF536A645B863C4ADB2078B932B354E04",
        "A6B858485748BF38BE193517AB90F8DE169EFF0989EA9360DB346A378B0FFE15",
        "50FFDEB807F8FF73A299A16000AA6575C5945BE875ADFC8795374ED3415249AC",
        "9F842D078755647C008E5FE3E12B839A981DE02A1F520CB2545CC04CD2323E0E",
        "B8CC75864D8EF461D8DD6AA7425E2C63C24D3982066B8D773A1549BFE24E05EE",
        "76BB7BBDD9F34E124A4573C3AA227E3C87CC603506697D054F6FDEC342E56EBF",
        "1FD6DD8FA0EC30D39E3F72E755B8A045BDE0F70449DC71008B767C2EAA89FB9F",
        "15D618BD7DB577BD9A8D45769C59E4FC631633BF447398A4B489B4C26FBC03AD",
        "B34EC592D2AC4993F5FFC85B15C3DA9078694051CB224345592AF7136D796C99",
        "9E91586DD4B115AB0568B21959E181F6545910BC5E2F30B8975CA09D7BC3EFCE",
        "769C824A1DADD19AEEFA420414D1732DAF44537F98AA229FC5477BCA55F9D59A",
    ]
    static let flags: [UInt8] = [1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1]

}

// Hex helpers shared by the setup helper and the patcher.
func hexToBytes(_ hex: String, _ n: Int) -> [UInt8]? {
    guard hex.count == n * 2 else { return nil }
    var out = [UInt8]()
    out.reserveCapacity(n)
    var it = hex.makeIterator()
    func nib(_ c: Character) -> UInt8? {
        if let d = c.hexDigitValue { return UInt8(d) }
        return nil
    }
    while let hi = it.next(), let lo = it.next() {
        guard let h = nib(hi), let l = nib(lo) else { return nil }
        out.append(h << 4 | l)
    }
    return out.count == n ? out : nil
}
