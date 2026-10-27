import SuwopShell
import SwiftUI

struct PhotoDuplicateMenu: View {
    let duplicate: (Provider, Bool) -> Void

    var body: some View {
        Menu("複製") {
            ForEach([Provider.apple, Provider.immich], id: \.self) { destination in
                let name = destination == .apple ? "Apple Photos" : "Immich"
                Button("原本を \(name) に複製") { duplicate(destination, false) }
                Button("現在の内容を \(name) に複製") { duplicate(destination, true) }
            }
        }
    }
}
