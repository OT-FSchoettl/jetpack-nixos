{
  lib,
  fetchurl,

  l4tVersion,
}:

let
  debsJSON = lib.importJSON (./r + "${lib.versions.major l4tVersion}.${lib.versions.minor l4tVersion}.json");
  baseURL = "https://repo.download.nvidia.com/jetson";
  repos = [ "common" ] ++ (
    if lib.version.major l4tVersion == "32" then ["T186"]
    else if lib.version.major l4tVersion == "35" then ["t194" "t234"]
    else []
  );

  fetchDeb = repo: pkg: fetchurl {
    url = "${baseURL}/${repo}/${pkg.filename}";
    sha256 = pkg.sha256;
  };
in
lib.mapAttrs (repo: pkgs: lib.mapAttrs (pkgname: pkg: pkg // { src = fetchDeb repo pkg; }) pkgs) debsJSON
