#!/usr/bin/perl
# MIT. Public implementation prepared from the deployment record; no subscriber data.
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use POSIX qw(WNOHANG);
BEGIN { my $d=__FILE__; $d =~ s{[^/]+$}{};unshift @INC,($d||'.'); }
use IptvConfig qw(load_config ipv4 allowed_ip parse_url);
my $cfgfile=shift @ARGV or die "usage: perl iptv_gateway.pl CONFIG\n";
die "unexpected_arguments\n" if @ARGV;
my $c=load_config($cfgfile);
my $bind=$c->{HTTP_BIND}||'127.0.0.1';my $port=$c->{HTTP_PORT}||8554;
die "listen_address_must_be_loopback_or_private_ipv4\n" unless allowed_ip($bind,'127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16');
die "invalid_port\n" unless $port=~/^\d+$/ && $port>=1024 && $port<=65535;
my $clients=$c->{CLIENT_CIDRS}||'127.0.0.1/32';
my $upnets=$c->{UPSTREAM_CIDRS}||'';my $upports=$c->{UPSTREAM_PORTS}||'554';
my $timeout=$c->{IO_TIMEOUT}||10;my $maxclients=$c->{MAX_CLIENTS}||4;
for($timeout,$maxclients){die "invalid_limits\n" unless /^\d+$/ && $_>=1 && $_<=300;}
my $ka=$c->{KEEPALIVE_SECONDS}||20;die "invalid_keepalive\n" unless $ka=~/^\d+$/&&$ka>=1&&$ka<=300;
my $playlist=$c->{SOURCE_M3U} or die "source_m3u_required\n";
my @songs;open(my $pf,'<',$playlist) or die "source_m3u_unreadable\n";my $label;
while(<$pf>) { s/\r?\n$//;next if /^\s*$/;
 if(/^#EXTINF:/){$label=$_;next;}next if /^#/;
 parse_url($_,$upnets,$upports);die "missing_channel_metadata\n" unless defined $label;
 push @songs,[$label,$_];$label=undef;die "playlist_too_large\n" if @songs>1000;
}close($pf);die "playlist_empty\n" unless @songs;
my $server=IO::Socket::INET->new(LocalAddr=>$bind,LocalPort=>$port,Proto=>'tcp',Listen=>16,ReuseAddr=>1) or die "listen_failed\n";
my %kids;my $running=1;$SIG{TERM}=$SIG{INT}=sub{$running=0};$SIG{PIPE}='IGNORE';$|=1;
print "gateway_ready\n";my $sel=IO::Select->new($server);
while($running) {
 while((my $pid=waitpid(-1,WNOHANG))>0){delete $kids{$pid};}
 next unless $sel->can_read(1);my $client=$server->accept() or next;
 if(!allowed_ip($client->peerhost,$clients)){http_error($client,403);close $client;next;}
 if(keys(%kids)>=$maxclients){http_error($client,503);close $client;next;}
 my $pid=fork();if(!defined $pid){close $client;next;}
 if(!$pid){$SIG{TERM}=$SIG{INT}='DEFAULT';close $server;eval{handle($client)};warn "request_failed\n" if $@;close $client;exit 0;}
 $kids{$pid}=1;close $client;
}
close $server;kill 'TERM',keys %kids if %kids;while(waitpid(-1,0)>0){};
sub write_all {
 my($s,$v)=@_;my $off=0;local $SIG{ALRM}=sub{die "write_timeout\n"};alarm($timeout);
 while($off<length $v){my $n=syswrite($s,$v,length($v)-$off,$off);die "write_failed\n" unless defined($n)&&$n>0;$off+=$n;}alarm(0);
}
sub http_error {my($s,$code)=@_;eval{write_all($s,"HTTP/1.0 $code Error\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")};}
sub read_more {
 my($s,$buf,$deadline)=@_;my $left=$deadline-time();die "upstream_timeout\n" if $left<=0;
 die "upstream_timeout\n" unless IO::Select->new($s)->can_read($left);
 my $n=sysread($s,my $v,32768);die "upstream_closed\n" unless defined($n)&&$n>0;$$buf.=$v;
 die "upstream_buffer_limit\n" if length($$buf)>2097152;
}
sub event {
 my($s,$buf)=@_;my $deadline=time()+$timeout;
 while(1){
  if(length($$buf)&&substr($$buf,0,1) eq '$'){
   if(length($$buf)>=4){my($ch,$len)=unpack('Cn',substr($$buf,1,3));if(length($$buf)>=4+$len){substr($$buf,0,4,'');return ['rtp',$ch,substr($$buf,0,$len,'')];}}
  }else{
   my $i=index($$buf,"\r\n\r\n");die "rtsp_header_limit\n" if $i<0&&length($$buf)>65536;
   if($i>=0){my $h=substr($$buf,0,$i);die "invalid_rtsp_response\n" unless $h=~/\ARTSP\/1\.0 \d{3}/;
    my $len=0;$len=$1 if $h=~/^Content-Length:\s*(\d+)\r?$/mi;die "rtsp_body_limit\n" if $len>1048576;
    if(length($$buf)>=$i+4+$len){my $msg=substr($$buf,0,$i+4+$len,'');return ['rtsp',$msg];}
   }
  }
  read_more($s,$buf,$deadline);
 }
}
sub header {my($s,$k)=@_;return $1 if $s=~/^\Q$k\E:[ \t]*([^\r\n]*)/mi;return undef;}
sub request {
 my($sock,$buf,$method,$url,$seq,$extra)=@_;$extra||='';
 write_all($sock,"$method $url RTSP/1.0\r\nCSeq: $seq\r\nUser-Agent: iptv-homelab/0.2\r\n$extra\r\n");
 my $e=event($sock,$buf);die "unexpected_interleaved_during_handshake\n" unless $e->[0] eq 'rtsp';
 my $n=header($e->[1],'CSeq');die "rtsp_cseq_mismatch\n" unless defined($n)&&$n eq "$seq";return $e->[1];
}
sub ts_payload {
 my($v)=@_;my $len=length($v);return '' unless $len;
 if(substr($v,0,1) ne "\x47" || $len%188){
  return '' if $len<12;my $b=ord(substr($v,0,1));return '' if ($b>>6)!=2;
  my $o=12+4*($b&15);return '' if $o>$len;
  if($b&16){return '' if $o+4>$len;$o+=4+4*unpack('n',substr($v,$o+2,2));return '' if $o>$len;}
  my $end=$len;if($b&32){my $pad=ord(substr($v,-1));return '' if !$pad||$pad>$len-$o;$end-=$pad;}
  return '' if $end<=$o;$v=substr($v,$o,$end-$o);
 }
 return '' unless length($v)%188==0;
 for(my $i=0;$i<length($v);$i+=188){return '' unless substr($v,$i,1) eq "\x47";}return $v;
}
sub handle {
 my($client)=@_;my $req='';my $deadline=time()+$timeout;
 until(index($req,"\r\n\r\n")>=0){read_more($client,\$req,$deadline);die "http_header_limit\n" if length($req)>16384;}
 my($path)=$req=~/\AGET ([^\s]+) HTTP\/1\.[01]\r\n/;
 unless(defined $path){http_error($client,400);return;}
 if($path eq '/playlist.m3u'){
  my $body="#EXTM3U\n";for my $i(0..$#songs){$body.=$songs[$i][0]."\n/channel/".($i+1)."\n";}
  # Absolute URLs require a trusted, operator-provided public base; never reflect Host.
  if(my $base=$c->{HTTP_BASE}){die "invalid_http_base\n" unless $base =~ m{\Ahttp://[0-9.]+:\d+\z};$body=~s{^/channel/}{$base/channel/}mg;}
  write_all($client,"HTTP/1.0 200 OK\r\nContent-Type: application/x-mpegurl\r\nContent-Length: ".length($body)."\r\nConnection: close\r\n\r\n$body");return;
 }
 unless($path=~m{\A/channel/([1-9]\d*)\z}&&$1<=@songs){http_error($client,404);return;}
 my $url=$songs[$1-1][1];my($up,$buf,$base,$session,$seq);$seq=1;my $sent=0;
 eval {
  for my $hop(0..8){
   my($host,$port,$tail)=parse_url($url,$upnets,$upports);$up=IO::Socket::INET->new(PeerHost=>$host,PeerPort=>$port,Proto=>'tcp',Timeout=>$timeout) or die "upstream_connect_failed\n";$buf='';
   my $r=request($up,\$buf,'DESCRIBE',$url,$seq++,"Accept: application/sdp\r\n");
   if($r=~/\ARTSP\/1\.0 30[12378] /){die "redirect_limit\n" if $hop==8;my $next=header($r,'Location') or die "redirect_without_location\n";parse_url($next,$upnets,$upports);close $up;$url=$next;next;}
   die "describe_failed\n" unless $r=~/\ARTSP\/1\.0 200 /;
   my($sdp)=($r=~/\r\n\r\n(.*)\z/s);die "unsupported_media_requires_mp2t\n" unless defined($sdp)&&($sdp=~/^m=\S+\s+\d+\s+RTP\/AVP\s+33(?:\s|$)/m||$sdp=~/^a=rtpmap:\d+ MP2T\/90000/mi);
   $base=header($r,'Content-Base')||$url;parse_url($base,$upnets,$upports);
   $session=header($r,'Session')||'';$session=~s/;.*//;last;
  }
  die "no_describe\n" unless defined $base;
  my $r=request($up,\$buf,'SETUP',$base,$seq++,($session?"Session: $session\r\n":'')."Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n");
  die "setup_failed\n" unless $r=~/\ARTSP\/1\.0 200 /;
  $session=header($r,'Session')||$session;$session=~s/;.*//;
  die "missing_session\n" unless length($session)&&$session!~/[\r\n]/;
  my $tr=header($r,'Transport')||'';die "tcp_interleaving_required\n" unless $tr=~/interleaved=0-1/ && $tr=~/TCP/i;
  $r=request($up,\$buf,'PLAY',$base,$seq++,"Session: $session\r\nRange: npt=now-\r\n");die "play_failed\n" unless $r=~/\ARTSP\/1\.0 200 /;
  write_all($client,"HTTP/1.0 200 OK\r\nContent-Type: video/mp2t\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");$sent=1;
  my $last=time();my $pending;
  while(1){
   die "keepalive_timeout\n" if defined($pending)&&time()-$last>=$timeout;
   if(time()-$last>=$ka && !defined($pending)){ $pending=$seq++;write_all($up,"OPTIONS $base RTSP/1.0\r\nCSeq: $pending\r\nSession: $session\r\n\r\n");$last=time(); }
   if(IO::Select->new($client)->can_read(0)){my $n=sysread($client,my $unused,1);last unless defined($n)&&$n>0;die "unexpected_http_client_data\n";}
   next if !length($buf) && !IO::Select->new($up)->can_read(1);
   my $e=event($up,\$buf);
   if($e->[0] eq 'rtp'){if($e->[1]==0){my $ts=ts_payload($e->[2]);die "invalid_mp2t_payload\n" unless length $ts;write_all($client,$ts);}}
   else {die "unexpected_rtsp_message\n" unless defined($pending)&&defined(header($e->[1],'CSeq'))&&header($e->[1],'CSeq') eq "$pending"&&$e->[1]=~/\ARTSP\/1\.0 200 /;$pending=undef;}
   die "keepalive_timeout\n" if defined($pending)&&time()-$last>=$timeout;
  }
 };
 my $error=$@;http_error($client,502) if $error&&!$sent;
 if($up&&defined($base)&&length($session||'')){eval{write_all($up,"TEARDOWN $base RTSP/1.0\r\nCSeq: $seq\r\nSession: $session\r\n\r\n")};}
 close $up if $up;warn "stream_ended\n" if $error;
}
