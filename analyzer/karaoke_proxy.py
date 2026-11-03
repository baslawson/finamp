"""Karaoke worker shares the analyzer's configured URL and authentication."""
import os
import requests
from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import Response, StreamingResponse


def router(authorize):
    from fastapi import Depends
    routes = APIRouter(dependencies=[Depends(authorize)])

    @routes.get('/karaoke')
    def catalogue(request: Request):
        base = os.environ.get('KARAOKE_URL', '').rstrip('/')
        if not base:
            raise HTTPException(503, 'Server karaoke is not installed yet')
        try:
            upstream = requests.get(base + '/karaoke', params=request.query_params,
                headers={'X-Api-Key': os.environ.get('ANALYZER_TOKEN', '')}, timeout=(5, 30))
        except requests.RequestException:
            raise HTTPException(503, 'Karaoke worker is unavailable; try again shortly') from None
        try:
            return Response(upstream.content, status_code=upstream.status_code, media_type='application/json')
        finally:
            upstream.close()

    @routes.api_route('/karaoke/{song}', methods=['GET', 'POST', 'DELETE'])
    @routes.get('/karaoke/{song}/audio')
    def proxy(song: str, request: Request):
        from karaoke import track_id
        track_id(song)
        base = os.environ.get('KARAOKE_URL', '').rstrip('/')
        if not base:
            raise HTTPException(503, 'Server karaoke is not installed yet')
        suffix = '/audio' if request.url.path.endswith('/audio') else ''
        headers = {'X-Api-Key': os.environ.get('ANALYZER_TOKEN', '')}
        if request.headers.get('range'):
            headers['Range'] = request.headers['range']
        try:
            upstream = requests.request(request.method, base + '/karaoke/' + song + suffix,
                                        params=request.query_params, headers=headers, stream=True, timeout=(5, 30))
        except requests.RequestException:
            raise HTTPException(503, 'Karaoke worker is unavailable; try again shortly') from None
        if not suffix or upstream.status_code >= 300:
            try:
                return Response(upstream.content, status_code=upstream.status_code,
                                media_type=upstream.headers.get('Content-Type', 'application/json'),
                                headers={k: v for k, v in upstream.headers.items() if k.lower() == 'content-range'})
            finally:
                upstream.close()

        def chunks():
            try:
                yield from upstream.iter_content(128 * 1024)
            finally:
                upstream.close()
        forwarded = {k: v for k, v in upstream.headers.items()
                     if k.lower() in ('content-length', 'content-range', 'accept-ranges', 'etag', 'cache-control')}
        return StreamingResponse(chunks(), status_code=upstream.status_code,
                                 media_type=upstream.headers.get('Content-Type', 'audio/flac'), headers=forwarded)

    return routes
