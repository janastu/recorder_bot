{ pkgs ? import <nixpkgs> { } }:
pkgs.mkShell {
  buildInputs = with pkgs; [
    libopus
    libopusenc
    libtoxcore
    nim
    openssl
    pkgconfig
  ];
  shellHook = ''
    export TOX_STATUS="nix shell $out"
  '';
}
