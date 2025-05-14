import React from "react";
import Header from "./Header";
import styles from "./styles.module.css";
import {MetaMask,OkxWallet,TokenPocket,WagmiWeb3ConfigProvider,WalletConnect,Hardhat,Mainnet} from "@ant-design/web3-wagmi";

interface LayoutProps {
  children: React.ReactNode;
}

const Layout: React.FC<LayoutProps> = ({ children }) => {
  return (
         <WagmiWeb3ConfigProvider
       eip6963={{
         autoAddInjectedWallets: true,
       }}
       ens
       chains={[Mainnet, Hardhat]}
       wallets={[
         MetaMask(),
         WalletConnect(),
         TokenPocket({
           group: "Popular",
         }),
         OkxWallet(),
       ]}
       walletConnect={{
         projectId: "c07c0051c2055890eade3556618e38a6",
       }}
     >
    <div className={styles.Layout}>
      <Header/>
      {children}
    </div>
    </WagmiWeb3ConfigProvider>
  );
};

export default Layout;