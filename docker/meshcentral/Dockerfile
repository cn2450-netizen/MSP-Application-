# MeshCentral with the optional modules it would otherwise npm-install at first start.
# Doing that at BUILD time means the container runs as an unprivileged user with no write access to its code and
# no npm/internet access at runtime, and the module versions are pinned here.
#
# The three modules below are exactly what MeshCentral 1.2.1 asks for when OIDC sign-in is enabled
# (its startup log: "Installing modules [ 'passport@0.7.0', 'connect-flash@0.1.1', 'openid-client@5.7.1' ]").
# When bumping MESH_TAG, start the new version once, read that line, and update the pins.
ARG MESH_TAG=1.2.6
FROM ghcr.io/ylianst/meshcentral:${MESH_TAG}-postgresql

# handlebars and proxy-addr are MeshCentral's own transitive dependencies; these two patch releases fix critical CVEs
# (found by the 2026-10-27 image scan) that 1.2.6 still ships. Drop them once MeshCentral bumps them itself.
RUN cd /opt/meshcentral/meshcentral \
 && npm install --no-audit --no-fund --no-optional --omit=optional \
      passport@0.7.0 connect-flash@0.1.1 openid-client@5.7.1 \
      handlebars@4.7.10 proxy-addr@2.0.8 \
 && npm cache clean --force
