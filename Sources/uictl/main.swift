import ArgumentParser
import Foundation

// ArgumentParser natively recognizes -h/--help. Normalize the other
// conventional help spellings onto it before parsing.
let helpAliases: Set<String> = ["-H", "--HELP", "-?"]
let arguments = CommandLine.arguments.dropFirst().map { helpAliases.contains($0) ? "--help" : $0 }

Root.main(Array(arguments))
