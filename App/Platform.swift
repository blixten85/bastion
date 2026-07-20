#if canImport(SwiftUI)
import SwiftUI
import SSHCore

// All plattformsskillnad mellan iOS och macOS samlad här, så vyerna slipper
// #if. Vår modelltyp aliasas också för att undvika krock med `Foundation.Host`
// (finns på macOS, inte iOS).
typealias Host = SSHCore.Host

extension View {
    /// Inline-titel på iOS; ingen effekt på macOS (som saknar API:t).
    @ViewBuilder func navInlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Stäng av autokapitalisering (bara iOS har begreppet).
    @ViewBuilder func noAutocap() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// Numeriskt tangentbord på iOS; ignoreras på macOS.
    @ViewBuilder func numberPad() -> some View {
        #if os(iOS)
        self.keyboardType(.numberPad)
        #else
        self
        #endif
    }

    /// Låter iOS Password AutoFill (inkl. tredjeparts-lösenordshanterare
    /// som Bitwarden/1Password, om installerade och aktiverade som AutoFill-
    /// leverantör i Inställningar) erbjuda ifyllnad för ett lösenordsfält —
    /// se gap-listepost #7 i [[project-bastion-termius-parity-mandate]].
    /// SSH är ingen webbadress, så det finns ingen domänkoppling som en
    /// webbläsares AutoFill — förslaget blir generellt/manuellt valt av
    /// användaren, inte automatiskt kopplat till just den här värden.
    /// `textContentType` finns bara på iOS, ingen effekt på macOS.
    @ViewBuilder func autofillPassword() -> some View {
        #if os(iOS)
        self.textContentType(.password)
        #else
        self
        #endif
    }

    /// Samma resonemang som `autofillPassword()`, för användarnamnsfältet
    /// bredvid — hjälper AutoFill matcha rätt par ur lösenordshanteraren.
    @ViewBuilder func autofillUsername() -> some View {
        #if os(iOS)
        self.textContentType(.username)
        #else
        self
        #endif
    }

    /// Presentera fullskärm på iOS, som ark på macOS (som saknar fullScreenCover).
    @ViewBuilder func cover<Item: Identifiable, Content: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item, content: content)
        #else
        self.sheet(item: item, content: content)
        #endif
    }

    @ViewBuilder func cover<Content: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }
}

extension Color {
    /// Kort-bakgrund som funkar på båda plattformar (ingen UIColor/NSColor).
    static var cardFill: Color { Color.secondary.opacity(0.12) }
}
#endif
