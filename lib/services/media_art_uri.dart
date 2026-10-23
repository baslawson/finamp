/// Keep authentication and size parameters when Android clients request artwork.
Uri androidMediaArtworkUri(Uri image, String authority) => Uri(
  scheme: 'content',
  host: authority,
  path: image.path,
  query: image.hasQuery ? image.query : null,
  fragment: const ['http', 'https'].contains(image.scheme) ? image.origin : null,
);
