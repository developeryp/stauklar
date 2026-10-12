import Foundation

/// Zugangsdaten für den Benachrichtigungs-Server (Supabase). Der „anon“-Schlüssel ist öffentlich
/// und erlaubt nur, das eigene Gerät zu registrieren; lesen kann damit niemand.
enum Config {
    static let supabaseURL = URL(string: "https://lcpfcgbfsibmankfwsqn.supabase.co")!
    static let supabaseKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxjcGZjZ2Jmc2libWFua2Z3c3FuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE3NjM3NjksImV4cCI6MjEwNzMzOTc2OX0.U4ed1xeezZsZy9IrY24P2pkaWVppIo-yWfsiXdEvln8"
}
