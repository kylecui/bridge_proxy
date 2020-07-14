# 透明网桥+Netfilter实现数据包无感知篡改

## 实现目标：
网络连接中串入一台设备，在对数据流量特征没有影响的情况下，对特定的网络包进行处理。处理后发送的包仍然保持原设备的IP地址和MAC地址

## 实现方式：
### 原始网络结构
```
服务器设备--------------------------终端设备
```
### 加入设备后
```
 服务器设备------------（物理口1）透明网桥（物理口2）---------终端设备
                      ｜                    ｜
                       \-------桥接---------/
                                |
                            netfilter
```
透明网桥加入后，绝大多数流量通过桥接直接转发到服务器设备。Netfilter对特定网络包进行处理，并交由用户态应用处理，然后重新发送出来。并且在发送出的最后阶段将IP地址和MAC地址修改为终端设备的相应地址。


## 实现步骤：
1. 设备准备：
Ubuntu 16.04, 三个网口（留一个管理口，作为测试管理使用）。物理口0（ens33）作为管理接口，接入公司网络。物理口1（ens34）接服务端，物理口2（ens35）接终端。在没有桥接的情况下，终端设备和服务端设备无法通信。
    1. 管理接口的配置如下：
    ```
    cat /etc/network/interfaces.d/ens33
    auto ens33
    iface ens33 inet dhcp
    ```

    2. 安装工具 
    `apt install iptables ebtables bridge-utils nginx`

    3. nginx做实验用。生产环境根据需要选择。配置如下：
    ```
    #/etc/nginx/sites-enabled/proxy_site
    server {
        listen  127.0.0.1:8899;
        location / {
                set $args "foo=1&bar=2&from=nginx";
                proxy_pass http://192.168.88.124/;
        }
    }
    ```

    4. 重启nginx 
    `service nginx restart`

2. 配置网桥：
    1. 关闭IPv6（避免干扰）：在/etc/sysctl.conf加入以下内容：
    ```
    #disable all ipv6
    net.ipv6.conf.all.disable_ipv6 = 1
    net.ipv6.conf.default.disable_ipv6 = 1
    net.ipv6.conf.lo.disable_ipv6 = 1
    ```
    2. 启用转发、bridge的iptables等：在/etc/sysctl.conf加入以下内容：
    ```
    #enable forward
    net.ipv4.ip_forward = 1

    #bridge works on the 2nd layer, need to enable bridge-nf for iptables.
    net.bridge.bridge-nf-call-ip6tables = 1
    net.bridge.bridge-nf-call-iptables = 1
    net.bridge.bridge-nf-call-arptables = 1

    #all the bridge to route traffic to localhost
    net.ipv4.conf.br0.route_localnet = 1
    net.ipv4.conf.all.route_localnet = 1
    ```
    3. 启用这些更改 
    `sysctl -p`
    4. 配置网桥：
    ```
    #/etc/network/interfaces.d/br0
    auto ens34
    iface ens34 inet manual

    auto ens35
    iface ens35 inet manual

    auto br0
    iface br0 inet static
    bridge_ports ens34
    bridge_ports ens35
    bridge_stp off
    bridge_fd 0
    address 0.0.0.0
    ```
    5. 重启网络服务以后可以看到网桥信息了
    ```
    >brctl show
    bridge name	bridge id		STP enabled	interfaces
    br0		8000.000c29c52da1	no		ens34
                                        ens35
    ```
    6. 网桥配置成功后，终端设备和服务器已经可以正常通信了。

    7. 因为网桥需要发起通信，所以需要配置一个ip地址。这个ip地址可以是任意地址。
    ```
    #config br0 ip address
    ifconfig br0 10.10.10.10/32
    ```
    同时需要添加路由信息：
    ```
    #config default gateway
    route add default gw 10.10.10.10
    ```

3. 配置netfilter：
    1. 设置接受所有的流量：
    ```
    iptables -P INPUT ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -P FORWARD ACCEPT
    ```
    2. 配置转发规则
    ```
    # 将来自终端设备（192.168.88.97），并且访问服务器设备（192.168.88.124）的目标端口为80的包转发到本地8899端口
    iptables -t nat -A PREROUTING -s 192.168.88.97/32 -d 192.168.88.124/32 -p tcp --dport 80 -j DNAT --to-destination 127.0.0.1:8899
    # 将即将发往访问服务器设备（192.168.88.124）的目标端口为80的包的原始ip修改为终端设备ip地址（192.168.88.97）
    iptables -t nat -A POSTROUTING -d 192.168.88.124/32 -p tcp --dport 80 -j SNAT --to-source 192.168.88.97
    ```
    3. 配置好以后，已经可以看到包被nginx上处理过了。服务器端收到的ip地址是设备端的地址，但此时服务器端收到的mac地址，是桥接口的地址，我们需要用ebtables将发出的包的地址也修改为设备端的mac
    ```
    # 默认接受所有的流量
    ebtables -P INPUT ACCEPT
    ebtables -P OUTPUT ACCEPT
    ebtables -P FORWARD ACCEPT
    # 将即将发往访问服务器设备（192.168.88.124）的包的原始mac修改为终端设备的mac地址
    ebtables -t nat -A POSTROUTING -p ipv4 --ip-dst 192.168.88.124 -j snat --to-source 00:0c:29:5f:91:cb
    ```
    4. 此时已经完全能够实现我们的需要了。
    
    ***注：如果遇到不能访问的情况，有可能是管理端口的路由出现冲突。可以使用ifconfig ens33 down关闭管理端口，或者使用route del删除管理端口的路由。***
    ```
    # 检查路由
    root@ubuntu:~# netstat -rn
    Kernel IP routing table
    Destination     Gateway         Genmask         Flags   MSS Window  irtt Iface
    0.0.0.0         10.10.10.10     0.0.0.0         UG        0 0          0 br0
    192.168.88.0    0.0.0.0         255.255.255.0   U         0 0          0 ens33
    # 将管理端口路由删除
    root@ubuntu:~# route del -net 192.168.88.0/24
    # 确认删除成功
    root@ubuntu:~# netstat -rn
    Kernel IP routing table
    Destination     Gateway         Genmask         Flags   MSS Window  irtt Iface
    0.0.0.0         10.10.10.10     0.0.0.0         UG        0 0          0 br0
    ```

4. 重启设备会造成iptables和ebtables的规则消失，可以保存一下规则：
    ```
    # 保存iptables
    iptables-save > iptables.conf
    # 保存ebtables
    ebtables-save > ebtables.conf
    ```
    重启以后可以使用如下命令将规则恢复
    ```
    # 恢复iptables
    iptables-restore < iptables.conf
    # 恢复ebtables
    ebtables-restore < ebtables.conf
    ```

    ***注：在我的环境中ebtables-restore不能正常工作，所以后面启动脚本没有使用ebtables-restore这个命令***

5. 写一个启动脚本。
    ```
    #!/bin/sh
    #配置网桥ip和路由
    ifconfig br0 10.10.10.10/32
    route add default gw 10.10.10.10
    #启动nginx服务
    service nginx start
    #还原iptables设置
    iptables-restore < iptables.conf
    #配置ebtables
    ebtables -P INPUT ACCEPT
    ebtables -P OUTPUT ACCEPT
    ebtables -P FORWARD ACCEPT
    ebtables -t nat -A POSTROUTING -p ipv4 --ip-dst 192.168.88.124 -j snat --to-source 00:0c:29:5f:91:cb
    ```