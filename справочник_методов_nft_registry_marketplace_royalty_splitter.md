Ниже — полный список методов для трёх модулей: NFT‑реестр (ERC‑721 + 2981), Маркетплейс (fixed + auction), Роялти‑сплиттер. Для каждого метода дано краткое назначение.

---

# 1) NFT‑реестр: `DomainRegistry721`

## Базовый ERC‑721
- **mint(address to, string tokenURI) → uint256 tokenId** — минт токена; создаёт новый NFT и назначает URI.
- **burn(uint256 tokenId)** — сжигает токен; доступно владельцу/approved.
- **safeTransferFrom(address from, address to, uint256 tokenId)** — безопасный перевод NFT.
- **transferFrom(address from, address to, uint256 tokenId)** — обычный перевод NFT.
- **approve(address to, uint256 tokenId)** — выдать разрешение на перевод конкретного токена.
- **setApprovalForAll(address operator, bool approved)** — глобальное разрешение оператору на все токены владельца.
- **ownerOf(uint256 tokenId) → address** — текущий владелец токена.
- **tokenURI(uint256 tokenId) → string** — метаданные токена (URI).

## Роялти (EIP‑2981)
- **royaltyInfo(uint256 tokenId, uint256 salePrice) → (address receiver, uint256 royaltyAmount)** — расчёт получателя и суммы роялти при продаже.
- **setDefaultRoyaltyBps(uint96 bps)** — задать общий процент роялти (в bps) по умолчанию.
- **setTreasury(address newTreasury)** — изменить адрес получателя роялти по умолчанию.
- **setTokenRoyalty(uint256 tokenId, address receiver, uint96 bps)** — пер‑токенный оверрайд роялти.
- **resetTokenRoyalty(uint256 tokenId)** — сброс пер‑токенного роялти к дефолтному.

## Доп. данные токена (рекомендуется)
- **creatorOf(uint256 tokenId) → address** — адрес минтера (создателя) данного токена.
- **mintedAt(uint256 tokenId) → uint64** — unix‑время минта.
- **getTokenData(uint256 tokenId) → (address creator, uint64 mintedAt, string uri, uint256 lastSalePrice, uint64 lastSaleAt)** — агрегированная информация по токену.
- **recordSale(uint256 tokenId, uint256 price, address buyer)** — запись факта продажи (для аналитики; обычно доступно маркетплейсу по роли SALES).

## Роли/админ/безопасность
- **grantRole(bytes32 role, address account)** — выдать роль.
- **revokeRole(bytes32 role, address account)** — отозвать роль.
- **renounceRole(bytes32 role, address account)** — владелец роли отказывается от неё.
- *(опц.)* **pause() / unpause()** — экстренная пауза (если используется Pausable).

---

# 2) Маркетплейс: `Marketplace`

## Листинги (фикс‑прайс)
- **listToken(address nft, uint256 tokenId, address currency, uint256 price) → uint256 listingId** — выставить NFT на продажу по фиксированной цене; сохраняет лот.
- **updateListing(uint256 listingId, uint256 newPrice)** — изменить цену лота.
- **cancelListing(uint256 listingId)** — снять лот с продажи.
- **buy(uint256 listingId)** — купить лот по фиксированной цене; переводит NFT и распределяет оплату (роялти/комиссия/продавец).

## Аукционы (английский)
- **createAuction(address nft, uint256 tokenId, address currency, uint256 startPrice, uint256 minBidStep, uint64 startTime, uint64 endTime) → uint256 auctionId** — создать аукцион с параметрами.
- **placeBid(uint256 auctionId, uint256 amount)** — сделать ставку; хранит лучшую ставку и возвраты предыдущей.
- **cancelAuction(uint256 auctionId)** — отменить аукцион до первой валидной ставки.
- **finalizeAuction(uint256 auctionId)** — завершить аукцион: передать NFT победителю, распределить платёж, зафиксировать событие продажи.

## Роялти и комиссии
- **setMarketplaceFeeBps(uint96 feeBps)** — задать комиссию маркетплейса в bps.
- **withdrawFees(address to)** — вывести накопленную комиссию маркетплейса на казначейский адрес.
- **payout(address nft, uint256 tokenId, address currency, uint256 salePrice, address seller, address buyer)** *(internal)* — единая функция распределения платежа: вызывает `royaltyInfo`, отправляет роялти, удерживает комиссию, остаток переводит продавцу.

## Просмотры/утилиты
- **getListing(uint256 listingId) → (…данные лота…)** — получить состояние лота.
- **getActiveListings(uint256 offset, uint256 limit) → (…список…)** — пагинированный список активных лотов.
- **getAuction(uint256 auctionId) → (…данные аукциона…)** — состояние аукциона.
- **getBids(uint256 auctionId) → (…список/лучшая ставка…)** — история ставок или лучшая ставка.

## Админ/безопасность
- **setAcceptedCurrency(address token, bool allowed)** — whitelist/ban поддерживаемых валют (напр., USDC).
- **setRegistry(address registry)** — установить адрес NFT‑реестра для интеграции (роль SALES, проверки).
- *(опц.)* **pause() / unpause()** — пауза контракта.
- Анти‑реэнтранси: `nonReentrant` на методах покупки/ставок/финализации.

---

# 3) Роялти‑сплиттер: `RoyaltySplitter`

## Инициализация
- **init(address creator, address treasury, uint16 creatorBps, uint16 treasuryBps)** — однократная инициализация (через клон); задаёт адреса и доли (сумма = 10000 bps).
- *(опц.)* **setSplits(uint16 creatorBps, uint16 treasuryBps)** — изменить пропорции (если политика проекта разрешает).

## Приём средств
- **receive() external payable** — приём нативного токена (MATIC); разносит доли внутри контракта на балансы получателей.
- **depositToken(address token, uint256 amount)** — приём ERC‑20 (через SafeERC20) с распределением долей по bps.

## Вывод средств (pull‑payments)
- **withdraw()** — вывести накопленный нативный баланс для `msg.sender`.
- **withdrawToken(address token)** — вывести накопленный баланс указанного ERC‑20 для `msg.sender`.

---

# Порядок распределения при продаже (внутри Marketplace)
1) `royaltyInfo(tokenId, salePrice)` → `receiver`, `royaltyAmount`.
2) Переводим `royaltyAmount` на `receiver` (если это `RoyaltySplitter`, он делит между `creator` и `treasury`).
3) Удерживаем `marketplaceFeeBps` → казна маркетплейса.
4) Остаток отправляем продавцу.
5) (опц.) вызываем в реестре `recordSale(tokenId, salePrice, buyer)` для аналитики.

---

# События (минимальный набор)
- **NFT‑реестр:** `Minted`, `SaleRecorded`, `DefaultRoyaltyUpdated`, `TreasuryUpdated` + стандартные `Transfer/Approval`.
- **Маркетплейс:** `Listed`, `ListingUpdated`, `ListingCanceled`, `Purchased`, `AuctionCreated`, `BidPlaced`, `AuctionFinalized`, `Payout`.
- **Сплиттер:** `Initialized`, `Received`, `TokenReceived`, `Withdraw`, `WithdrawToken`.

---

> Этого списка достаточно, чтобы написать интерфейсы и перейти к реализациям. Если нужно, могу сгенерировать каркас `.sol` файлов с пустыми телами функций под эти сигнатуры, чтобы ты сразу начал заполнять логику.

