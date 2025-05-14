import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton,Connector } from "@ant-design/web3";
import styles from "./styles.module.css";

export default function Header() {
  const pathname = usePathname();
  const isSwapPage = pathname === "/swap"
  return (
    <div className={styles.header}>
      <div className={styles.title}>Swap</div>
      <div className={styles.nav}>
        <Link href="/swap"
          className={isSwapPage ? styles.active : undefined}>Swap</Link>
        <Link href="/swap/pool"
          className={!isSwapPage ? styles.active : undefined}>Pool</Link>
      </div>
      <div>
        <Connector
          modalProps={{
            mode:"simple"
          }}
          ><ConnectButton type="text" /></Connector>
      </div>
    </div>
  );
  }
  