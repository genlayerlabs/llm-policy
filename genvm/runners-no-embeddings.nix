# runners-no-embeddings.nix — replicates genvm's debug-runners derivation but
# skips MiniLM embeddings + dependent py-libs. Lets us assemble a build/out/runners
# tree that's good enough for LLM tests (call_llm.py), without modifying genvm.
#
# The MiniLM derivation has a hash mismatch upstream (HuggingFace changed the model
# tarball); embeddings aren't needed for plain LLM cascading tests.
#
# Usage:
#   nix-build /home/jm/docs/genlayer/llm-router/genvm/runners-no-embeddings.nix
#   # then copy result/ to <genvm>/build/out/runners/

let
  genvmRoot = builtins.toPath /home/jm/docs/genlayer/genvm;

  allRunners = import "${genvmRoot}/runners" { host-system = "x86_64-linux"; };

  excludeIds = [
    "models-all-MiniLM-L6-v2"
    "py-lib-genlayer-embeddings"
    "py-lib-protobuf"
    "py-lib-word_piece_tokenizer"
  ];

  filteredRunners = builtins.filter
    (r: !(builtins.elem r.id excludeIds))
    allRunners;

  pkgs-pure = builtins.fetchGit {
    url = "https://github.com/NixOS/nixpkgs";
    rev = "2ff43b1d533641116f1740158d121013036a7f74";
    shallow = true;
  };
  pkgs = import pkgs-pure { system = "x86_64-linux"; };

  pathOfRunner = runner:
    let
      hash32 =
        if runner.hash == "test"
        then "test"
        else builtins.convertHash { hash = runner.hash; toHashFormat = "nix32"; };
    in "${runner.id}/${builtins.substring 0 2 hash32}/${builtins.substring 2 50 hash32}.tar";

  installLines =
    builtins.concatLists
      (builtins.map
        (x: [
          "mkdir -p $out/$(dirname -- ${pathOfRunner x})"
          "cp ${x.derivation} $out/${pathOfRunner x}"
        ])
        filteredRunners);
in
pkgs.stdenvNoCC.mkDerivation {
  name = "genvm-debug-runners-no-emb";
  phases = [ "installPhase" ];
  installPhase = builtins.concatStringsSep "\n" (installLines ++ [""]);
}
