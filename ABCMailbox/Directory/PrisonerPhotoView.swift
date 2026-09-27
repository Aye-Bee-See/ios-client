import ABCCore
import SwiftUI

/// A prisoner's photograph (API #130). A hosted one loads at once: the API serves it with ordinary HTTP caching
/// (`Cache-Control`, an `ETag`), so the shared URL cache is all it needs. An off-site one waits for a tap, because
/// loading it tells that other site that this phone is looking at this prisoner.
struct PrisonerPhotoView: View {
  let photo: PrisonerPhoto
  let name: String
  let apiBase: URL?
  @State private var showOffSite = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if photo.hosted || showOffSite, let base = apiBase, let address = photo.address(apiBase: base) {
        AsyncImage(url: address) { phase in
          switch phase {
          case .success(let image): image.resizable().scaledToFill()
          case .failure: Image(systemName: "person.crop.rectangle").font(.system(size: 48)).foregroundStyle(Theme.inkMuted).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.paperRaised)
          default: Theme.paperRaised
          }
        }
        .frame(maxWidth: .infinity).frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("Photo of \(name)")
      } else if let host = photo.offSiteHost {
        Button("Show the photo from \(host)") { showOffSite = true }.buttonStyle(.link)
        Muted("The photo is kept on another site, which would learn that this phone looked at it.", font: Theme.caption)
      }
      if let credit = photo.credit { Muted(credit, font: Theme.caption) }
    }
  }
}
