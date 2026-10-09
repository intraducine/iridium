"""Route Windows appearance editing through the runtime-neutral frontend editor."""


def apply(name, text):
    if name != 'Library.swift':
        return text
    start = 'case "Rename & Artwork": Form {'
    end = 'case "Controls": Form {'
    if text.count(start) != 1 or text.count(end) != 1:
        raise ValueError('Madeira artwork destination changed')
    a, b = text.index(start), text.index(end)
    if b <= a:
        raise ValueError('Madeira artwork destination order changed')
    replacement = '''case "Rename & Artwork":
                    IridiumArtworkEditor(game: IridiumGame(windows: entry), embedded: true,
                                         onBack: {
                                             if iridiumPages.last == "Rename & Artwork" { iridiumNavigate("back") }
                                         })
                        .navigationBarBackButtonHidden()
                    '''
    text = text[:a] + replacement + text[b:]
    start, end = 'struct LibraryArtwork: View {', '\n/// A pseudo-random sequence'
    if text.count(start) != 1 or text.count(end) != 1:
        raise ValueError('Madeira artwork view changed')
    a, b = text.index(start), text.index(end)
    text = text[:a] + """struct LibraryArtwork: View {
    let entry: LibraryEntry
    var backdrop = false
    var body: some View { IridiumGameArtwork(game: IridiumGame(windows: entry), backdrop: backdrop) }
}
""" + text[b:]
    old = 'Text(entry.title).font(.title2.bold()).lineLimit(2)'
    new = 'Text(IridiumArtworkModel.shared.title(IridiumGame(windows: entry))).font(.title2.bold()).lineLimit(2)'
    if text.count(old) != 1:
        raise ValueError('Madeira artwork detail title changed')
    text = text.replace(old, new)
    start, end = 'struct LibraryDetail: View {', '\n/// Game details'
    a, b = text.index(start), text.index(end, text.index(start))
    detail = text[a:b]
    old = '''    @ViewBuilder private func artwork(backdrop: Bool) -> some View {
        if let appID = entry.steamAppID, entry.coverFile == nil {
            SteamGameArtwork(appID: appID)
        } else {
            LibraryArtwork(entry: entry, backdrop: backdrop)
        }
    }'''
    new = '''    @ViewBuilder private func artwork(backdrop: Bool) -> some View {
        LibraryArtwork(entry: entry, backdrop: backdrop)
    }'''
    hooks = [
        (old, new),
        ('            .onReceive(LibraryController.shared.commands) { command in\n',
         '            .onReceive(LibraryController.shared.commands) { command in\n'
         '                guard iridiumPages.last != "Rename & Artwork" else { return }\n'),
        ('.onKeyPress(.escape) { iridiumNavigate("back"); return .handled }',
         '.onKeyPress(.escape, phases: .down) { _ in\n'
         '                guard iridiumPages.last != "Rename & Artwork" else { return .ignored }\n'
         '                iridiumNavigate("back"); return .handled\n'
         '            }'),
    ]
    for old, new in hooks:
        if detail.count(old) != 1:
            raise ValueError('Madeira shared artwork ownership changed: ' + old[:80])
        detail = detail.replace(old, new)
    return text[:a] + detail + text[b:]
