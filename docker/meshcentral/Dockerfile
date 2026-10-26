# MeshCentral with the optional modules it would otherwise npm-install at first start.
# Doing that at BUILD time means the container runs as an unprivileged user with no write access to its code and
# no npm/internet access at runtime, and the module versions are pinned here.
#
# The three modules below are exactly what MeshCentral 1.2.1 asks for when OIDC sign-in is enabled
# (its startup log: "Installing modules [ 'passport@0.7.0', 'connect-flash@0.1.1', 'openid-client@5.7.1' ]").
# When bumping MESH_TAG, start the new version once, read that line, and update the pins.
ARG MESH_TAG=1.2.1
FROM ghcr.io/ylianst/meshcentral:${MESH_TAG}-postgresql

RUN cd /opt/meshcentral/meshcentral \
 && npm install --no-audit --no-fund --no-optional --omit=optional \
      passport@0.7.0 connect-flash@0.1.1 openid-client@5.7.1 \
 && npm cache clean --force
