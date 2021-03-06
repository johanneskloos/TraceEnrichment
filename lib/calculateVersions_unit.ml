open Kaputt.Abbreviations
open TypesJS
open TestBaseData

let (|>) = Pervasives.(|>)

let test_calculate_versions =
  Test.make_simple_test ~title:"calculate_versions" (fun () ->
      same_facts_tracefile
        (functab1, objtab1, facttrace1, globals, true)
        (CalculateVersions.collect_versions_trace
           (functab1, objtab1, argtrace1, globals, true)))

let tests = [ test_calculate_versions ]
