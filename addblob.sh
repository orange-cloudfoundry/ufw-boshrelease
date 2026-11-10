#!/bin/bash
set -x
set -e -o pipefail

echo "Current blobs"
bosh blobs

NEW_BLOBS_WERE_ADDED="false"

# params
# $1: src
# $2: target
function addBlobOnChecksumChange() {
  src="$1"
  target="$2"
  if [ ! -f "$src" ]; then
    echo "ERROR: $src not found — run ./vendor.sh before ./addblob.sh" >&2
    exit 1
  fi
  blob_checksum=$(cat config/blobs.yml | yq .'"'${target}'"'.sha)
  blob_object_id=$(cat config/blobs.yml | yq .'"'${target}'"'.object_id) # With dev release, blobs are not published yet, so we need to add it again
  src_checksum=$(sha256sum "${src}" | cut -d " " -f1)
  if [ "${blob_checksum}" != "sha256:${src_checksum}" ] || [ "$blob_object_id" = "null" ]; then
    bosh add-blob "${src}" "${target}"
    NEW_BLOBS_WERE_ADDED="true"
  else
    echo "skipping blob creation for ${target} with existing checksum: ${src_checksum}"
  fi
}

# target name is version-stable (ufw.orig.tar.gz) so package spec/glob never
# changes on an upstream bump; the version lives in vendir.yml + blobs.yml sha
addBlobOnChecksumChange src/ufw/tarball/ufw_0.36.1.orig.tar.gz ufw/ufw.orig.tar.gz

# Inspired by https://github.com/orange-cloudfoundry/bosh-release-action/blob/8732ff085712d9980fc66e50892cb9c3d7a3f884/entrypoint.sh#L48-L58
function configureS3BlobStore() {
  if [ ! -z "${AWS_BOSH_ACCES_KEY_ID}" ]; then
    cat - > config/private.yml <<EOS
---
blobstore:
  options:
    access_key_id: ${AWS_BOSH_ACCES_KEY_ID}
    secret_access_key: ${AWS_BOSH_SECRET_ACCES_KEY}
EOS
  else
    echo "::warning::AWS_BOSH_ACCES_KEY_ID not set, skipping config/private.yml"
  fi
}

configureS3BlobStore

if [ "${NEW_BLOBS_WERE_ADDED}" == "true" ] ; then
  echo "Current blobs before upload"
  bosh blobs

  if [ -f config/private.yml ]; then
    # See https://bosh.io/docs/release-blobs/#saving-blobs
    bosh upload-blobs
    echo "Current blobs after upload"
    bosh blobs
  else
    echo "No blobstore credentials: blobs stay in local blobs/ dir (dev release mode)"
  fi
fi
