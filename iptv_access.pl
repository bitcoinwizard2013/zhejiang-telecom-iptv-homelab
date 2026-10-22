#!/usr/bin/perl
# MIT. Dedicated-interface access and explicitly owned routes only.
use strict;
use warnings;
use Fcntl qw(:DEFAULT :flock);
BEGIN { my $d=__FILE__; $d =~ s{[^/]+$}{};unshift @INC,($d||'.'); }
use IptvConfig qw(load_config ipv4 read_state write_state);
my $dir=__FILE__;$dir=~s{[^/]+$}{};$dir||='./';$dir='./'.$dir unless $dir=~m{^/};require "${dir}iptv_dhcp.pl";
sub capture {my(@args)=@_;open(my $f,'-|',@args) or die "command_start_failed\n";local $/;my $v=<$f>//'';close($f) or die "command_read_failed\n";return $v;}
sub change {system(@_)==0 or die "network_command_failed\n";}
sub prefixes {
 my($s)=@_;my @p=split(',',$s||'');die "prefixes_required\n" unless @p;
 for(@p){die "invalid_prefix\n" unless m{\A([0-9.]+)/(\d+)\z}&&$2>=8&&$2<=32;
  my($n,$bits)=(ipv4($1),$2);die "invalid_prefix\n" unless defined($n)&&$n>0&&$n<0xe0000000;my $mask=(0xffffffff<<(32-$bits))&0xffffffff;die "unaligned_prefix\n" if ($n&$mask)!=$n;}
 my %seen;die "duplicate_prefix\n" if grep{$seen{$_}++}@p;return @p;
}
sub route {my($ip,$p)=@_;return capture($ip,'-4','route','show','exact',$p);}
sub route_owned {my($text,$p,$gw,$iface)=@_;$text=~s/\s+$//;return $text eq "$p via $gw dev $iface";}
sub apply_access {
 my($c,$statefile)=@_;my $ip=$c->{IP_BINARY}||'/sbin/ip';my $iface=$c->{IPTV_INTERFACE};my @p=prefixes($c->{IPTV_PREFIXES});
 die "invalid_interface\n" unless ($iface||'')=~/\A[A-Za-z0-9_.:-]{1,15}\z/;
 die "bridge_member_refused\n" if -l "/sys/class/net/$iface/master";
 my $defaults=capture($ip,'-4','route','show','default');die "default_route_interface_refused\n" if $defaults=~/\bdev \Q$iface\E(?:\s|$)/;
 my $link=capture($ip,'-o','link','show','dev',$iface);my($mac)=$link=~/link\/ether ([0-9a-f:]{17})/i;die "ethernet_interface_required\n" unless $mac;
 my $old=read_state($statefile);my $addr=capture($ip,'-o','-4','addr','show','dev',$iface);my @addrs=($addr=~/\binet ([0-9.]+\/\d+)/g);
 die "interface_contains_unmanaged_addresses\n" if grep{$_ ne ($old->{ADDRESS}||'')}@addrs;
 my $wanted=lc($c->{STB_MAC_HEX}||'');die "invalid_stb_mac\n" unless $wanted=~/^[0-9a-f]{12}$/&&!(hex(substr($wanted,0,2))&1)&&$wanted ne '000000000000';
 $wanted=join(':',$wanted=~/(..)/g);
 if(%$old){die "configuration_changed_remove_owned_state_first\n" unless ($old->{INTERFACE}||'') eq $iface&&($old->{ROUTES}||'') eq join(',',@p)&&($old->{CURRENT_MAC}||'') eq $wanted;die "interface_mac_changed_externally\n" unless lc($mac) eq $wanted;}
 for my $p(@p){my $r=route($ip,$p);die "existing_unmanaged_route_refused\n" if length($r)&&(!%$old||!route_owned($r,$p,$old->{GATEWAY},$iface));}
 if(%$old && -e "$statefile.lease"){
  my $l=read_state("$statefile.lease");
  if(($l->{ACQUIRED}||0)+($l->{T1}||0)>time()){
   my($ownedip,$pref)=split('/',$old->{ADDRESS});
   change($ip,'addr','add',$old->{ADDRESS},'dev',$iface) unless grep{$_ eq $old->{ADDRESS}}@addrs;
   for my $p(@p){change($ip,'route','add',$p,'via',$old->{GATEWAY},'dev',$iface) unless length(route($ip,$p));}
   return 'lease_not_due';
  }
 }
 my $was_up=($link=~/<[^>]*\bUP\b/)?1:0;my $changed_mac=0;my(@added_routes,$added_addr);my $success=eval{
  if(!%$old&&lc($mac) ne $wanted){change($ip,'link','set','dev',$iface,'down');change($ip,'link','set','dev',$iface,'address',$wanted);$changed_mac=1;}
  change($ip,'link','set','dev',$iface,'up');
  my($current)=split('/',$old->{ADDRESS}||'');my $l=acquire($c,$current||undef,0);my $cidr="$l->{IP}/$l->{PREFIX}";
  die "lease_changed_remove_owned_state_then_reacquire\n" if %$old&&($old->{ADDRESS} ne $cidr||$old->{GATEWAY} ne $l->{GATEWAY});
  die "off_subnet_gateway_not_supported\n" unless (($l->{GATEWAY}=~/\A[0-9.]+\z/) && (ipv4($l->{IP})>>(32-$l->{PREFIX}))==(ipv4($l->{GATEWAY})>>(32-$l->{PREFIX})));
  unless(grep{$_ eq $cidr}@addrs){change($ip,'addr','add',$cidr,'dev',$iface);$added_addr=$cidr;}
  for my $p(@p){my $existing=route($ip,$p);die "route_conflict_during_apply\n" if length($existing)&&(!%$old||!route_owned($existing,$p,$old->{GATEWAY},$iface));unless(length($existing)){change($ip,'route','add',$p,'via',$l->{GATEWAY},'dev',$iface);push @added_routes,[$p,$l->{GATEWAY}];}}
  die "default_route_changed_externally\n" unless capture($ip,'-4','route','show','default') eq $defaults;
  my %state=(INTERFACE=>$iface,ADDRESS=>$cidr,GATEWAY=>$l->{GATEWAY},ROUTES=>join(',',@p),OLD_MAC=>$old->{OLD_MAC}||lc($mac),CURRENT_MAC=>$wanted,OLD_UP=>%$old?$old->{OLD_UP}:$was_up);
  write_state("$statefile.lease",$l);write_state($statefile,\%state);1;
 };
 unless($success){my $error=$@;
  for my $entry(reverse @added_routes){my($p,$gw)=@$entry;eval{change($ip,'route','del',$p,'via',$gw,'dev',$iface) if route_owned(route($ip,$p),$p,$gw,$iface);};}
  eval{change($ip,'addr','del',$added_addr,'dev',$iface)} if $added_addr;
  if($changed_mac){eval{change($ip,'link','set','dev',$iface,'down');change($ip,'link','set','dev',$iface,'address',$mac)};}
  eval{change($ip,'link','set','dev',$iface,$was_up?'up':'down')} unless %$old;
  if(%$old && -e "$statefile.lease"){my $lease=read_state("$statefile.lease");if(($lease->{ACQUIRED}||0)+($lease->{SECONDS}||0)<=time()){eval{remove_access($c,$statefile)};}}
  die $error;
 }
 return 'access_ready';
}
sub remove_access {
 my($c,$statefile)=@_;my $s=read_state($statefile);return 'nothing_owned' unless %$s;
 my $ip=$c->{IP_BINARY}||'/sbin/ip';my $iface=$s->{INTERFACE};
 die "default_route_interface_refused\n" if capture($ip,'-4','route','show','default')=~/\bdev \Q$iface\E(?:\s|$)/;
 die "bridge_member_refused\n" if -l "/sys/class/net/$iface/master";
 my $link=capture($ip,'-o','link','show','dev',$iface);die "interface_mac_changed_externally\n" unless $link=~/link\/ether \Q$s->{CURRENT_MAC}\E(?:\s|$)/i;
 my @a=(capture($ip,'-o','-4','addr','show','dev',$iface)=~/\binet ([0-9.]+\/\d+)/g);die "interface_contains_unmanaged_addresses\n" if grep{$_ ne $s->{ADDRESS}}@a;
 my @p=prefixes($s->{ROUTES});for my $p(@p){my $r=route($ip,$p);die "owned_route_changed_externally\n" if length($r)&&!route_owned($r,$p,$s->{GATEWAY},$iface);}
 for my $p(@p){change($ip,'route','del',$p,'via',$s->{GATEWAY},'dev',$iface) if length(route($ip,$p));}
 change($ip,'addr','del',$s->{ADDRESS},'dev',$iface) if @a;
 change($ip,'link','set','dev',$iface,'down');change($ip,'link','set','dev',$iface,'address',$s->{OLD_MAC});change($ip,'link','set','dev',$iface,'up') if $s->{OLD_UP};
 unlink($statefile);unlink("$statefile.lease");return 'owned_access_removed';
}
sub main {
 my $mode=shift(@ARGV)||'--plan';my $file=shift(@ARGV)||'/etc/iptv-homelab/iptv.conf';die "invalid_arguments\n" if @ARGV||$mode!~/\A--(?:plan|apply|watch|remove)\z/;
 my $c=load_config($file);my @p=prefixes($c->{IPTV_PREFIXES});
 die "invalid_interface\n" unless ($c->{IPTV_INTERFACE}||'')=~/\A[A-Za-z0-9_.:-]{1,15}\z/;
 if($mode eq '--plan'){print "Plan: dedicated-interface DHCP identity; ".scalar(@p)." explicit routes; no default route, DNS, NAT or firewall changes.\n";return;}
 die "live_access_requires_linux_root\n" unless $^O eq 'linux'&&$<==0;
 my $state=$c->{STATE_FILE}||'/var/run/iptv-homelab/access.state';die "absolute_state_path_required\n" unless $state=~m{\A/[A-Za-z0-9_./-]+\z};
 my $parent=$state;$parent=~s{/[^/]+$}{};mkdir($parent,0700) unless -d $parent;die "state_directory_unsafe\n" if -l $parent||((stat($parent))[2]&077);
 sysopen(my $lock,"$state.lock",O_WRONLY|O_CREAT,0600) or die "lock_create_failed\n";flock($lock,LOCK_EX|LOCK_NB) or die "access_already_running\n";
 if($mode eq '--remove'){print remove_access($c,$state)."\n";return;}
 my $stop=0;$SIG{TERM}=$SIG{INT}=sub{$stop=1;die "access_interrupted\n";};
 if($mode eq '--apply'){print apply_access($c,$state)."\n";return;}
 while(!$stop){eval{print apply_access($c,$state)."\n"};warn "access_retry_pending\n" if $@&&!$stop;last if $stop;sleep(30);}
}
main() unless caller;
1;
