"""Offline protocol fixture for real installed CLIs. Never forwards requests."""
import http.server
import base64
import hashlib
import json
import pathlib
import sys
import time
import uuid
from urllib.parse import urlsplit

root = pathlib.Path(sys.argv[1])

def image_summaries(value):
    """Record only hashes of synthetic fixture images, never the image bytes."""
    images = []
    if isinstance(value, dict):
        encoded = None
        if value.get('type') == 'image' and value.get('source', {}).get('type') == 'base64':
            encoded = value['source'].get('data')
        elif value.get('type') == 'input_image' and isinstance(value.get('image_url'), str):
            url = value['image_url']
            if url.startswith('data:image/') and ';base64,' in url:
                encoded = url.split(';base64,', 1)[1]
        if encoded:
            data = base64.b64decode(encoded, validate=True)
            images.append({'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data)})
        for child in value.values(): images.extend(image_summaries(child))
    elif isinstance(value, list):
        for child in value: images.extend(image_summaries(child))
    return images

class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({'data': [{'id': 'fixture-one'}, {'id': 'fixture-two'}]}).encode())

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        path = urlsplit(self.path).path
        if 'count_tokens' in path:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"input_tokens":10}')
            return
        if not (path.endswith('/messages') or path.endswith('/responses')):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{}')
            return
        with (root / 'requests.jsonl').open('a') as output:
            output.write(json.dumps({'model': body.get('model'), 'count': len(body.get('messages', body.get('input', []))), 'images': image_summaries(body)}) + '\n')
        if path.endswith('/messages') and not body.get('stream'):
            result = {'id': 'probe', 'type': 'message', 'role': 'assistant', 'model': body['model'], 'content': [{'type': 'text', 'text': 'OK'}], 'stop_reason': 'end_turn', 'stop_sequence': None, 'usage': {'input_tokens': 1, 'output_tokens': 1}}
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result).encode())
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        def event(kind, **fields):
            self.wfile.write(('event: ' + kind + '\ndata: ' + json.dumps({'type': kind, **fields}) + '\n\n').encode())
            self.wfile.flush()
        mid = 'msg_' + uuid.uuid4().hex
        text = 'Local fixture reply for ' + body['model']
        if path.endswith('/messages'):
            event('message_start', message={'id': mid, 'type': 'message', 'role': 'assistant', 'model': body['model'], 'content': [], 'stop_reason': None, 'stop_sequence': None, 'usage': {'input_tokens': 10, 'output_tokens': 0}})
            command_file = root / 'tool-command.txt'
            if command_file.exists() and not (root / 'tool-requested').exists():
                (root / 'tool-requested').touch()
                event('content_block_start', index=0, content_block={'type': 'tool_use', 'id': 'fixture-command', 'name': 'Bash', 'input': {}})
                event('content_block_delta', index=0, delta={'type': 'input_json_delta', 'partial_json': json.dumps({'command': command_file.read_text(), 'description': 'Run local offline fixture tests'})})
                event('content_block_stop', index=0)
                event('message_delta', delta={'stop_reason': 'tool_use', 'stop_sequence': None}, usage={'output_tokens': 10})
                event('message_stop')
                return
            for message in body.get('messages', []):
                for block in message.get('content', []) if isinstance(message.get('content'), list) else []:
                    if isinstance(block, dict) and block.get('type') == 'tool_result' and block.get('tool_use_id') == 'fixture-command':
                        (root / 'tool-result.json').write_text(json.dumps(block))
            event('content_block_start', index=0, content_block={'type': 'text', 'text': ''})
            event('content_block_delta', index=0, delta={'type': 'text_delta', 'text': text})
            event('content_block_stop', index=0)
            event('message_delta', delta={'stop_reason': 'end_turn', 'stop_sequence': None}, usage={'output_tokens': 5})
            event('message_stop')
        else:
            rid = 'resp_' + uuid.uuid4().hex
            response = {'id': rid, 'object': 'response', 'created_at': int(time.time()), 'model': body['model']}
            command_file = root / 'tool-command.txt'
            if command_file.exists() and not (root / 'tool-requested').exists():
                (root / 'tool-requested').touch()
                names = [tool.get('name') for tool in body.get('tools', [])]
                command = command_file.read_text()
                if 'exec_command' in names:
                    name, arguments = 'exec_command', {'cmd': command, 'yield_time_ms': 10000}
                elif 'shell_command' in names:
                    name, arguments = 'shell_command', {'command': command, 'timeout_ms': 30000}
                else:
                    name, arguments = 'shell', {'command': ['/bin/sh', '-c', command], 'timeout_ms': 30000}
                arguments = json.dumps(arguments)
                item = {'id': mid, 'type': 'function_call', 'status': 'completed', 'call_id': 'fixture-command', 'name': name, 'arguments': arguments}
                event('response.created', response={**response, 'status': 'in_progress', 'output': []})
                event('response.output_item.added', output_index=0, item={**item, 'status': 'in_progress', 'arguments': ''})
                event('response.function_call_arguments.delta', item_id=mid, output_index=0, delta=arguments)
                event('response.output_item.done', output_index=0, item=item)
                event('response.completed', response={**response, 'status': 'completed', 'output': [item], 'usage': {'input_tokens': 10, 'output_tokens': 10, 'total_tokens': 20}})
                return
            for item in body.get('input', []):
                if isinstance(item, dict) and item.get('type') == 'function_call_output' and item.get('call_id') == 'fixture-command':
                    (root / 'tool-result.json').write_text(json.dumps(item))
            item = {'id': mid, 'type': 'message', 'status': 'completed', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': text, 'annotations': []}]}
            event('response.created', response={**response, 'status': 'in_progress', 'output': []})
            event('response.output_item.added', output_index=0, item={**item, 'status': 'in_progress', 'content': []})
            event('response.content_part.added', item_id=mid, output_index=0, content_index=0, part={'type': 'output_text', 'text': '', 'annotations': []})
            event('response.output_text.delta', item_id=mid, output_index=0, content_index=0, delta=text)
            event('response.output_item.done', output_index=0, item=item)
            event('response.completed', response={**response, 'status': 'completed', 'output': [item], 'usage': {'input_tokens': 10, 'output_tokens': 5, 'total_tokens': 15}})

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
