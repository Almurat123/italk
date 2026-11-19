import Foundation
while let line = readLine() {
    let a = MandarinCompletion.assess(line)
    print(line + "\t" + a.rawValue)
}
