import ABCCore
import SwiftUI

/// A prisoner's photograph, hosted by the API (API #130). It is served with ordinary HTTP caching
/// (`Cache-Control`, an `ETag`), so the shared URL cache is all it needs.
struct PrisonerPhotoView: View {
  let photo: PrisonerPhoto
  let name: String
  let apiBase: URL?

  var body: some View {
    if let base = apiBase, let address = photo.address(apiBase: base) {
      VStack(alignment: .leading, spacing: 4) {
        AsyncImage(url: address) { phase in
          switch phase {
          case .success(let image): image.resizable().scaledToFill()
          case .failure: Image(systemName: "person.crop.rectangle").font(.system(size: 48)).foregroundStyle(Theme.inkMuted).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.paperRaised)
          default: Theme.paperRaised
          }
        }
        // Square, as uploads are cropped: a wide frame would cut the top and bottom off a face.
        .frame(width: 240, height: 240).clipShape(RoundedRectangle(cornerRadius: 4))
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Photo of \(name)")
        if let credit = photo.credit { Muted(credit, font: Theme.caption) }
      }
    }
  }
}
