{ lib, fetchurl }:

let
  debsJSON = lib.importJSON ./r32.4.json;
  baseURL = "https://repo.download.nvidia.com/jetson";
  repos = [ "T186" "common"];

  fetchDeb = repo: pkg: fetchurl {
    url = "${baseURL}/${repo}/${pkg.filename}";
    sha256 = pkg.sha256;
  };
in
lib.mapAttrs (repo: pkgs: lib.mapAttrs (pkgname: pkg: pkg // { src = fetchDeb repo pkg; }) pkgs) debsJSON
