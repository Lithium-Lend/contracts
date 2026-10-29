export function classifyVerification(contract, address, legacy) {
  const published = typeof contract?.source_code === 'string' && contract.source_code.trim().length > 0;
  if (published && contract.is_verified === true) {
    if (contract.is_partially_verified === true) return 'partial';
    if (contract.is_fully_verified === true && contract.is_partially_verified === false) return 'full';
    return 'published-unclassified';
  }
  if (legacy?.status === '1' && Array.isArray(legacy.result) && legacy.result.some(r => typeof r.SourceCode === 'string' && r.SourceCode.trim().length > 0)) return 'published-unclassified';
  if (address?.is_contract === true && address.is_verified === false) return 'unverified';
  return 'unknown';
}

export async function inspectVerification(component, fetcher = fetch) {
  const origin = 'https://liteforge.explorer.caldera.xyz';
  const get = async path => {
    try {
      const response = await fetcher(`${origin}${path}`, { signal: AbortSignal.timeout(15000) });
      return { httpStatus: response.status, data: response.ok ? await response.json() : undefined };
    } catch { return { httpStatus: null }; }
  };
  const source = await get(`/api/v2/smart-contracts/${component.address}`);
  let address, legacy;
  if (!source.data?.source_code || source.data.is_fully_verified !== true) {
    [address, legacy] = await Promise.all([
      get(`/api/v2/addresses/${component.address}`),
      get(`/api?module=contract&action=getsourcecode&address=${component.address}`),
    ]);
  }
  return {
    address: component.address, role: component.role,
    status: classifyVerification(source.data, address?.data, legacy?.data),
    explorerUrl: `${origin}/address/${component.address}?tab=contract`,
    checkedAt: new Date().toISOString(),
    httpStatus: { source: source.httpStatus, address: address?.httpStatus, legacy: legacy?.httpStatus },
    name: source.data?.name,
    compiler: source.data?.compiler_version,
    flags: source.data ? { verified: source.data.is_verified, full: source.data.is_fully_verified, partial: source.data.is_partially_verified } : undefined,
    sourcePublished: Boolean(source.data?.source_code) || Boolean(legacy?.data?.result?.some?.(r => r.SourceCode)),
  };
}
