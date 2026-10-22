#!/usr/bin/env python3
"""Isolated fixtures only: localhost sockets and documentation-range addresses."""
import contextlib,json,os,pathlib,re,socket,struct,subprocess,tempfile,threading,time,unittest,urllib.request,urllib.error
ROOT=pathlib.Path(__file__).resolve().parent
PERL='/usr/bin/perl'
TS=b'\x47'+b'\0'*187

def free_port():
    with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def config(path,values):
    path.write_text(''.join(f'{k}={v}\n' for k,v in values.items()));path.chmod(0o600)
def read_headers(conn,buf=b''):
    while b'\r\n\r\n' not in buf:
        chunk=conn.recv(8192)
        if not chunk:raise EOFError
        buf+=chunk
    return buf.split(b'\r\n\r\n',1)
class RTSP:
    def __init__(self,mode='stream',redirect=None):
        self.mode=mode;self.redirect=redirect;self.errors=[];self.options=0;self.connections=0
        self.sock=socket.socket();self.sock.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);self.sock.bind(('127.0.0.1',0));self.port=self.sock.getsockname()[1];self.sock.listen();self.sock.settimeout(.2);self.stop=False
        self.thread=threading.Thread(target=self.run,daemon=True);self.thread.start()
    def run(self):
        while not self.stop:
            try:conn,_=self.sock.accept()
            except socket.timeout:continue
            except OSError:break
            self.connections+=1
            try:
                with conn:
                    conn.settimeout(4);buf=b''
                    while True:
                        h,buf=read_headers(conn,buf);method=h.split(b' ',1)[0];seq=re.search(rb'CSeq: (\d+)',h).group(1)
                        def reply(status=200,extra=b'',body=b''):
                            conn.sendall(b'RTSP/1.0 '+str(status).encode()+b' OK\r\nCSeq: '+seq+b'\r\n'+extra+b'Content-Length: '+str(len(body)).encode()+b'\r\n\r\n'+body)
                        if self.mode=='redirect':reply(302,b'Location: '+self.redirect.encode()+b'\r\n');break
                        if self.mode=='cseq':
                            conn.sendall(b'RTSP/1.0 200 OK\r\nCSeq: 9999\r\nContent-Length: 0\r\n\r\n');break
                        if method==b'DESCRIBE':
                            media=b'm=video 0 RTP/AVP 33\r\n' if self.mode!='unsupported' else b'm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n'
                            reply(extra=f'Content-Base: rtsp://127.0.0.1:{self.port}/fixture?ticket=synthetic\r\n'.encode(),body=b'v=0\r\n'+media)
                        elif method==b'SETUP':
                            assert b'RTP/AVP/TCP;unicast;interleaved=0-1' in h
                            reply(extra=b'Session: fixture-session;timeout=30\r\nTransport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n')
                        elif method==b'PLAY':
                            reply();payload=bytes([0x90,33])+b'\0'*10+b'\x10\x00\x00\x01'+b'\0'*4+TS
                            frame=b'$\x00'+struct.pack('!H',len(payload))+payload
                            # Deliberately split the interleaved header and payload across reads.
                            for a,b in [(0,2),(2,7),(7,23),(23,len(frame))]:conn.sendall(frame[a:b]);time.sleep(.03)
                            # RTCP channel is not video; raw TS on channel 0 is also supported.
                            conn.sendall(b'$\x01\x00\x04FAKE'+b'$\x00'+struct.pack('!H',len(TS))+TS)
                        elif method==b'OPTIONS':
                            self.options+=1
                            if self.mode!='no_keepalive':reply()
                            if self.mode!='no_keepalive':conn.sendall(b'$\x00'+struct.pack('!H',len(TS))+TS)
                        elif method==b'TEARDOWN':break
            except (EOFError,ConnectionError,socket.timeout,OSError):pass
            except Exception as e:self.errors.append(repr(e))
    def close(self):self.stop=True;self.sock.close();self.thread.join(timeout=1)
@contextlib.contextmanager
def gateway(mode='stream',clients='127.0.0.1/32',redirect=False):
    with tempfile.TemporaryDirectory() as d:
        d=pathlib.Path(d);up=RTSP(mode);origin=up
        if redirect:origin=RTSP('redirect',f'rtsp://127.0.0.1:{up.port}/fixture')
        port=free_port();cfg=d/'iptv.conf';m3u=d/'source.m3u';m3u.write_text(f'#EXTM3U\n#EXTINF:-1,Fixture\nrtsp://127.0.0.1:{origin.port}/fixture\n')
        config(cfg,dict(HTTP_BIND='127.0.0.1',HTTP_PORT=port,HTTP_BASE=f'http://127.0.0.1:{port}',CLIENT_CIDRS=clients,UPSTREAM_CIDRS='127.0.0.1/32',UPSTREAM_PORTS=f'{origin.port},{up.port}',SOURCE_M3U=m3u,IO_TIMEOUT=2,KEEPALIVE_SECONDS=1,MAX_CLIENTS=3))
        p=subprocess.Popen([PERL,str(ROOT/'iptv_gateway.pl'),str(cfg)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            for _ in range(60):
                if p.poll() is not None:raise RuntimeError('gateway startup failed')
                try:
                    with socket.create_connection(('127.0.0.1',port),timeout=.1):break
                except OSError:time.sleep(.05)
            yield f'http://127.0.0.1:{port}',up,cfg
        finally:
            p.terminate()
            try:out,err=p.communicate(timeout=4)
            except subprocess.TimeoutExpired:p.kill();out,err=p.communicate(timeout=2)
            up.close()
            if origin is not up:origin.close()
            assert b'ticket=synthetic' not in out+err,'URL query leaked into log'
            assert not up.errors,up.errors
class RuntimeTests(unittest.TestCase):
    def test_syntax_and_installer_plan(self):
        for name in ['iptv_gateway.pl','iptv_dhcp.pl','iptv_access.pl']:
            r=subprocess.run([PERL,'-c',str(ROOT/name)],capture_output=True);self.assertEqual(r.returncode,0,r.stderr)
        for name in ['install.sh','iptv-homelab.init','doctor.sh']:
            self.assertEqual(subprocess.run(['sh','-n',str(ROOT/name)],capture_output=True).returncode,0)
        r=subprocess.run(['sh',str(ROOT/'install.sh'),'--plan'],capture_output=True);self.assertEqual(r.returncode,0)
    def test_playlist_and_invalid_path(self):
        with gateway() as (base,up,_):
            body=urllib.request.urlopen(base+'/playlist.m3u',timeout=4).read();self.assertIn((base+'/channel/1').encode(),body);self.assertNotIn(b'rtsp://',body)
            self.assertEqual(up.connections,0)
            with self.assertRaises(urllib.error.HTTPError) as e:urllib.request.urlopen(base+'/arbitrary-url',timeout=4)
            self.assertEqual(e.exception.code,404);e.exception.close()
    def test_fragmentation_rtp_extension_rtcp_raw_and_keepalive(self):
        with gateway() as (base,up,_):
            with urllib.request.urlopen(base+'/channel/1',timeout=5) as r:
                data=r.read(188*3)
            self.assertEqual(data,TS*3);self.assertGreaterEqual(up.options,1)
    def test_redirect_and_allowlist(self):
        with gateway(redirect=True) as (base,up,_):
            with urllib.request.urlopen(base+'/channel/1',timeout=4) as r:self.assertEqual(r.read(188),TS)
        with gateway('redirect') as (base,up,_):
            up.redirect='rtsp://127.0.0.2:554/not-allowed'
            with self.assertRaises(urllib.error.HTTPError) as e:urllib.request.urlopen(base+'/channel/1',timeout=4)
            self.assertEqual(e.exception.code,502);e.exception.close()
    def test_client_acl_media_and_cseq(self):
        with gateway(clients='192.0.2.0/24') as (base,_,_):
            with self.assertRaises(urllib.error.HTTPError) as e:urllib.request.urlopen(base+'/playlist.m3u',timeout=4)
            self.assertEqual(e.exception.code,403);e.exception.close()
        for mode in ['unsupported','cseq']:
            with self.subTest(mode=mode),gateway(mode) as (base,_,_):
                with self.assertRaises(urllib.error.HTTPError) as e:urllib.request.urlopen(base+'/channel/1',timeout=4)
                self.assertEqual(e.exception.code,502);e.exception.close()
    def test_dhcp_dora_wrong_xid_and_server_id(self):
        with tempfile.TemporaryDirectory() as d:
            d=pathlib.Path(d);srv=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);srv.bind(('127.0.0.1',0));srv.settimeout(5);errors=[];seen=[]
            def options(v):
                r={};i=240
                while i<len(v):
                    code=v[i];i+=1
                    if code==255:break
                    if code==0:continue
                    size=v[i];i+=1;r[code]=v[i:i+size];i+=size
                return r
            def run():
                try:
                    for mode in [2,5]:
                        req,peer=srv.recvfrom(8192);o=options(req);seen.append(o)
                        boot=bytearray(req[:240]);boot[0]=2;boot[16:20]=socket.inet_aton('192.0.2.20')
                        body=b'\x35\x01'+bytes([mode])+b'\x36\x04'+socket.inet_aton('192.0.2.1')+b'\x01\x04\xff\xff\xff\x00'+b'\x03\x04'+socket.inet_aton('192.0.2.254')+b'\x33\x04'+struct.pack('!I',120)+b'\xff'
                        bad=bytearray(boot);bad[4]^=255;srv.sendto(bytes(bad)+body,peer);srv.sendto(bytes(boot)+body,peer)
                except Exception as e:errors.append(repr(e))
            thread=threading.Thread(target=run);thread.start();cfg=d/'conf';out=d/'lease'
            config(cfg,dict(IPTV_INTERFACE='fixture0',STB_MAC_HEX='020000000001',OPTION60_HEX='11223344',DHCP_HOSTNAME='fixture',MOCK_DHCP_PORT=srv.getsockname()[1]))
            r=subprocess.run([PERL,str(ROOT/'iptv_dhcp.pl'),'--config',str(cfg),'--output',str(out),'--mock-loopback'],capture_output=True,timeout=12);thread.join(timeout=6);srv.close()
            self.assertEqual(r.returncode,0,r.stderr);self.assertFalse(errors,errors);self.assertEqual(seen[1][54],socket.inet_aton('192.0.2.1'));self.assertNotEqual(seen[1][54],socket.inet_aton('192.0.2.254'))
            self.assertIn('PREFIX=24',out.read_text());self.assertEqual(out.stat().st_mode&0o777,0o600);self.assertNotIn(b'11223344',r.stdout+r.stderr)
    def test_config_permissions(self):
        with tempfile.TemporaryDirectory() as d:
            cfg=pathlib.Path(d)/'config';cfg.write_text('HTTP_BIND=127.0.0.1\n');cfg.chmod(0o644)
            r=subprocess.run([PERL,str(ROOT/'iptv_gateway.pl'),str(cfg)],capture_output=True);self.assertNotEqual(r.returncode,0);self.assertIn(b'config_permissions',r.stderr)
    def test_keepalive_failure_closes_stream(self):
        with gateway('no_keepalive') as (base,up,_):
            t=time.monotonic()
            with urllib.request.urlopen(base+'/channel/1',timeout=6) as r:data=r.read()
            self.assertEqual(data,TS*2);self.assertLess(time.monotonic()-t,6);self.assertGreaterEqual(up.options,1)
    def test_dhcp_parser_rejects_truncation_and_bad_mask(self):
        xid=b'\x01\x02\x03\x04';mac=bytes.fromhex('020000000001')
        packet=bytearray(240);packet[0:4]=bytes([2,1,6,0]);packet[4:8]=xid;packet[16:20]=socket.inet_aton('192.0.2.20');packet[28:34]=mac;packet[236:240]=bytes.fromhex('63825363')
        opts=b'\x35\x01\x05\x36\x04'+socket.inet_aton('192.0.2.1')
        for body in [bytes(packet)+opts+b'\x01\x04\xff\x00\xff\x00\xff',bytes(packet)+opts+b'\x01\x04\xff',bytes(packet)+opts+b'\x35\x01\x05\xff']:
            code='require shift; local $/;my $v=<STDIN>;my $r=decode($v,pack("H*","01020304"),pack("H*","020000000001"));exit(defined($r)?1:0);'
            r=subprocess.run([PERL,'-e',code,str(ROOT/'iptv_dhcp.pl')],input=body,capture_output=True);self.assertEqual(r.returncode,0,r.stderr)
    def test_owned_routes_apply_remove_conflict_and_rollback(self):
        # Replace command/DHCP adapters; never invoke ip or a live network interface.
        harness=r'''
use strict;use warnings;
my($source,$mode,$state)=@ARGV;require $source;
my %routes;my @addresses;my @changes;my $mac='02:00:00:00:00:02';
my $defaults="default via 203.0.113.1 dev main0\n";
$routes{'192.0.2.0/24'}="192.0.2.0/24 via 192.0.2.254 dev unmanaged0\n" if $mode eq 'conflict';
my $before=$routes{'192.0.2.0/24'}||'';
{
 no warnings 'redefine';
 *main::capture=sub{my($binary,@a)=@_;my $v=join(' ',@a);
  return $defaults if $v eq '-4 route show default';
  return "1: fixture0: <BROADCAST,MULTICAST,UP> mtu 1500 link/ether $mac\n" if $v eq '-o link show dev fixture0';
  return join('',map{"1: fixture0 inet $_ scope global fixture0\n"}@addresses) if $v eq '-o -4 addr show dev fixture0';
  return $routes{$a[-1]}||'' if $v=~/^-4 route show exact /;
  die "unexpected read $v\n";
 };
 *main::change=sub{my($binary,@a)=@_;my $v=join(' ',@a);push @changes,$v;
  if($v=~/^link set dev fixture0 address (\S+)$/){$mac=$1;return;}
  return if $v=~/^link set dev fixture0 (?:up|down)$/;
  if($v=~/^addr add (\S+) dev fixture0$/){push @addresses,$1;return;}
  if($v=~/^addr del (\S+) dev fixture0$/){my $x=$1;@addresses=grep{$_ ne $x}@addresses;return;}
  if($v=~/^route add (\S+) via (\S+) dev fixture0$/){my($p,$g)=($1,$2);die "simulated_route_failure\n" if $mode eq 'rollback'&&$p eq '198.51.100.0/24';$routes{$p}="$p via $g dev fixture0\n";return;}
  if($v=~/^route del (\S+) via (\S+) dev fixture0$/){delete $routes{$1};return;}
  die "unexpected change $v\n";
 };
 *main::acquire=sub{return {IP=>'203.0.113.20',PREFIX=>24,GATEWAY=>'203.0.113.254',SECONDS=>120,T1=>60,ACQUIRED=>time()};};
}
my $c={IP_BINARY=>'/not-invoked/ip',IPTV_INTERFACE=>'fixture0',STB_MAC_HEX=>'020000000001',IPTV_PREFIXES=>'192.0.2.0/24,198.51.100.0/24'};
my $ok=eval{apply_access($c,$state);1};
if($mode eq 'conflict'){die 'conflict not preserved' if $ok||@changes||$routes{'192.0.2.0/24'} ne $before;}
elsif($mode eq 'rollback'){die 'rollback failed' if $ok||keys(%routes)||@addresses||$mac ne '02:00:00:00:00:02';}
else {die "apply failed: $@" unless $ok;die 'missing state' unless -e $state;apply_access($c,$state);remove_access($c,$state);die 'remove failed' if keys(%routes)||@addresses||-e($state)||$mac ne '02:00:00:00:00:02';}
print "fixture_pass\n";
'''
        with tempfile.TemporaryDirectory() as d:
            for mode in ['normal','conflict','rollback']:
                with self.subTest(mode=mode):
                    r=subprocess.run([PERL,'-e',harness,str(ROOT/'iptv_access.pl'),mode,str(pathlib.Path(d)/'state')],capture_output=True)
                    self.assertEqual(r.returncode,0,r.stderr)

if __name__=='__main__':unittest.main(verbosity=2)
