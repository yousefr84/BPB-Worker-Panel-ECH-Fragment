import { base64DecodeUtf8, base64EncodeUtf8 } from '@common';
import { getSettings } from '@settings';
import { buildFinalMask, buildTlsSettings } from '@xray/outbounds';
import type { FinalMask } from '#types/xray';
import {
    generateRemark,
    generateWsPath,
    getConfigAddresses,
    getProtocols,
    isBase64,
    isHttps,
    selectSniHost
} from '@utils';

interface RawUriOptions {
    protocol: string;
    address: string;
    port: number;
    host: string;
    sni: string;
    remark: string;
    tls: boolean;
    ech?: string;
    fragment?: FinalMask;
}

export function buildRawUri({
    protocol,
    address,
    port,
    host,
    sni,
    remark,
    tls,
    ech,
    fragment
}: RawUriOptions): string {
    const { fingerprint, vlUUID, trPass, client } = getSettings();
    const security = tls ? 'tls' : 'none';
    const config = new URL(`${protocol}://config`);

    if (protocol === _VL_) {
        config.username = vlUUID;
        config.searchParams.append('encryption', 'none');
    } else {
        config.username = trPass;
    }

    const path = generateWsPath(protocol);
    config.hostname = address;
    config.port = port.toString();
    config.searchParams.append('host', host);
    config.searchParams.append('type', 'ws');
    config.searchParams.append('security', security);
    config.hash = remark;

    if (client === 'sing-box') {
        config.searchParams.append('eh', 'Sec-WebSocket-Protocol');
        config.searchParams.append('ed', '2560');
        config.searchParams.append('path', path);
    } else {
        config.searchParams.append('path', `${path}?ed=2560`);
    }

    if (tls) {
        config.searchParams.append('sni', sni);
        config.searchParams.append('fp', fingerprint);
        config.searchParams.append('alpn', 'http/1.1');
    }

    if (protocol === _VL_) {
        // Xray's `ech` share-link parameter maps to tlsSettings.echConfigList.
        if (ech) config.searchParams.append('ech', ech);
        // Xray's `fm` parameter carries URL-encoded streamSettings.finalmask JSON.
        if (fragment) config.searchParams.append('fm', JSON.stringify(fragment));
    }

    return config.href;
}

export async function getURLConfigs() {
    return getRawConfigs(false);
}

export async function getRawEchFragmentConfigs() {
    return getRawConfigs(true);
}

async function getRawConfigs(includeEchFragment: boolean) {
    const {
        fingerprint,
        ports,
        chainProxy,
        remoteDNS,
        customConfigs,
        customSubs,
        customDomain,
        httpsPorts,
        mainDomain,
        enableECH,
        echServerName,
        upstreamParams: { upstreamServer, upstreamPort }
    } = getSettings();

    let VLConfs = '', TRConfs = '', chainConfig = '';
    let proxyIndex = 1;
    const domains = [mainDomain].concatIf(!!customDomain, customDomain);
    const protocols = getProtocols();

    for (const domain of domains) {
        const totalPorts = ports.filter(port => domain.endsWith('workers.dev') || isHttps(port));
        const addrs = await getConfigAddresses(domain, false);
        if (upstreamServer && upstreamPort) {
            totalPorts.unshift(upstreamPort);
            addrs.unshift(upstreamServer);
        }

        for (const port of totalPorts) {
            for (const addr of addrs) {
                const { sni, host } = selectSniHost(addr, domain);
                if ((port === upstreamPort) !== (addr === upstreamServer)) continue;
                const isTLS = httpsPorts.includes(port) || addr === upstreamServer;
                const ech = includeEchFragment && isTLS
                    ? buildTlsSettings(
                        sni,
                        fingerprint,
                        'http/1.1',
                        enableECH,
                        echServerName || undefined
                    ).echConfigList
                    : undefined;
                const fragment = includeEchFragment
                    ? buildFinalMask(true, false)
                    : undefined;

                if (protocols.includes(_VL_)) {
                    const remark = generateRemark(proxyIndex, port, addr, _VL_, domain, false, false);
                    const vlConfig = buildRawUri({
                        protocol: _VL_,
                        address: addr,
                        port,
                        host,
                        sni,
                        remark,
                        tls: isTLS,
                        ech,
                        fragment
                    });
                    VLConfs += `${vlConfig}\n`;
                }

                if (protocols.includes(_TR_)) {
                    const remark = generateRemark(proxyIndex, port, addr, _TR_, domain, false, false);
                    const trConfig = buildRawUri({
                        protocol: _TR_,
                        address: addr,
                        port,
                        host,
                        sni,
                        remark,
                        tls: isTLS
                    });
                    TRConfs += `${trConfig}\n`;
                }

                proxyIndex++;
            }
        }
    }

    if (chainProxy) {
        let chainRemark = `#${encodeURIComponent('💦 Chain proxy 🔗')}`;
        if (chainProxy.startsWith('socks') || chainProxy.startsWith('http')) {
            const regex = /^(?:socks|http):\/\/([^@]+)@/;
            const isUserPass = chainProxy.match(regex);
            const userPass = isUserPass ? isUserPass[1] : false;
            chainConfig = userPass
                ? chainProxy.replace(userPass, btoa(userPass)) + chainRemark
                : chainProxy + chainRemark;
        } else {
            chainConfig = chainProxy.split('#')[0] + chainRemark;
        }
    }

    const customConfs = customConfigs.join('\n') + await fetchCustomSubs(customSubs);
    const configs = base64EncodeUtf8(VLConfs + TRConfs + chainConfig + customConfs);

    return new Response(configs, {
        status: 200,
        headers: {
            'Content-Type': 'text/plain; charset=utf-8',
            'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
            'Pragma': 'no-cache',
            'Expires': '0',
            'Profile-Title': `base64:${base64EncodeUtf8(`💦 ${_project_} ${includeEchFragment ? 'Raw ECH Fragment' : 'Raw'}`)}`,
            'DNS': remoteDNS
        }
    });
}

async function fetchCustomSubs(subs: string[]): Promise<string> {
    const results = await Promise.all(
        subs.map(async (url) => {
            try {
                const res = await fetch(url);
                if (!res.ok) return '';

                const text = (await res.text()).trim();
                if (!text) return '';

                if (isBase64(text)) {
                    try {
                        return base64DecodeUtf8(text);
                    } catch {
                        return text;
                    }
                }

                return text;
            } catch {
                return '';
            }
        })
    );

    return results
        .filter(Boolean)
        .join('\n');
}
