# Radish Architecture

## Core Data Structures

```mermaid
classDiagram
    class RadishContext {
        Dict~String, RadishElement~
    }

    class RadishElement {
        +Any value
        +Union~Int128, Nothing~ ttl
        +DateTime tinit
        +Symbol datatype
    }

    class ExecutionStatus {
        <<enumeration>>
        SUCCESS
        KEY_NOT_FOUND
        ERROR
    }

    RadishContext *-- RadishElement : contains
```

## Hypercommand Execution Flow

This sequence diagram illustrates how a command (e.g., `S_GET`) is processed through the delegation pattern.

```mermaid
sequenceDiagram
    participant Client
    participant Dispatcher
    participant Hypercommand as Hypercommand (rget_or_expire!)
    participant Context as RadishContext
    participant TypeCmd as TypeCommand (sget)

    Client->>Dispatcher: S_GET "mykey"
    Dispatcher->>Dispatcher: Lookup Palette ("S_GET")
    Dispatcher->>Hypercommand: Parse & Call rget_or_expire!(ctx, "mykey", sget)
    
    activate Hypercommand
    Hypercommand->>Context: Check Key Exists?
    alt Key Missing
        Hypercommand-->>Dispatcher: nothing (KEY_NOT_FOUND)
    else Key Exists
        Hypercommand->>Context: Check TTL (Expired?)
        alt Expired
            Hypercommand->>Context: Delete Key
            Hypercommand-->>Dispatcher: nothing (KEY_NOT_FOUND)
        else Valid
            Hypercommand->>TypeCmd: sget(element.value, args...)
            activate TypeCmd
            TypeCmd-->>Hypercommand: Result Value
            deactivate TypeCmd
            Hypercommand-->>Dispatcher: Result Value (SUCCESS)
        end
    end
    deactivate Hypercommand

    Dispatcher-->>Client: Response (Value or Nil)
```

## Command Palette Structure

```mermaid
graph TD
    subgraph Palettes
        S[S_PALETTE String]
        L[LL_PALETTE List]
        N[NOKEY_PALETTE Context]
    end

    subgraph Commands
        S_GET --> |maps to| H1[rget_or_expire!]
        S_GET --> |uses| T1[sget]
        
        S_SET --> |maps to| H2[radd!]
        S_SET --> |uses| T2[sadd]

        L_POP --> |maps to| H3[rget_on_modify_or_expire!]
        L_POP --> |uses| T3[lpop!]
    end

    S --> S_GET
    S --> S_SET
    L --> L_POP
```
